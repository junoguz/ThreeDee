//
//  FaceTracker.swift
//  ThreeDee
//
//  Passive front-camera head tracking for the viewer's parallax effect.
//  Frames are analysed on-device with Vision and immediately discarded; only
//  the latest face position/size is kept.
//

import AVFoundation
import QuartzCore
import Vision

nonisolated final class FaceTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Pose: Sendable {
        /// Face centre in a selfie-mirrored, upright frame (0…1, origin bottom-left).
        var x: Float = 0.5
        var y: Float = 0.5
        /// Face width relative to the frame width; grows as the face approaches.
        var size: Float = 0
        var timestamp: CFTimeInterval = 0
        var valid = false
    }

    enum Status: Sendable, Equatable {
        case idle, starting, searching, tracking, denied, unavailable
    }

    private let lock = NSLock()
    private var latest = Pose()
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "threedee.face.session")
    private let videoQueue = DispatchQueue(label: "threedee.face.video", qos: .userInitiated)
    private var configured = false
    private var lastProcessed: CFTimeInterval = 0
    private var lastSeen: CFTimeInterval = 0
    private let sequenceHandler = VNSequenceRequestHandler()
    private var status: Status = .idle
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var connection: AVCaptureConnection?

    /// Called on the main queue whenever the status changes.
    var onStatus: (@Sendable (Status) -> Void)?

    var pose: Pose { lock.withLock { latest } }

    static var hasFrontCamera: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
    }

    #if DEBUG
    /// Synthetic head motion for verifying the parallax mapping without a camera (`-fakeHead`).
    private var fakeTimer: DispatchSourceTimer?
    private func startFakeHead() {
        let timer = DispatchSource.makeTimerSource(queue: videoQueue)
        let start = CACurrentMediaTime()
        timer.schedule(deadline: .now(), repeating: 1.0 / 20.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let t = CACurrentMediaTime() - start
            // Hold still for 5 s (baseline), then move left/up and lean in.
            let move = Float(min(max((t - 5) / 1.0, 0), 1))
            lock.withLock {
                self.latest = Pose(x: 0.5 - 0.18 * move, y: 0.5 + 0.12 * move, size: 0.3 * (1 + 0.25 * move),
                              timestamp: CACurrentMediaTime(), valid: true)
            }
            report(.tracking)
        }
        timer.resume()
        fakeTimer = timer
    }
    #endif

    func start() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-fakeHead") {
            startFakeHead()
            return
        }
        #endif
        // Don't ask for camera permission on hardware without a front camera (e.g. Simulator).
        guard FaceTracker.hasFrontCamera else {
            report(.unavailable)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            report(.starting)
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted { self.startSession() } else { self.report(.denied) }
            }
        default:
            report(.denied)
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
            lock.withLock { latest.valid = false }
            report(.idle)
        }
    }

    private func startSession() {
        report(.starting)
        sessionQueue.async { [self] in
            if !configured && !configure() {
                report(.unavailable)
                return
            }
            if !session.isRunning { session.startRunning() }
            report(session.isRunning ? .searching : .unavailable)
        }
    }

    private func configure() -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
        guard session.canAddInput(input) else { return false }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)
        if let c = output.connection(with: .video) {
            // Mirror like a selfie so moving your head left moves the face left in the frame.
            if c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = true
            }
            connection = c
        }
        // Keep the frame rate (and power draw) low; the effect is smoothed anyway.
        if (try? device.lockForConfiguration()) != nil {
            let target = CMTime(value: 1, timescale: 24)
            if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameDuration <= target && target <= $0.maxFrameDuration }) {
                device.activeVideoMinFrameDuration = target
                device.activeVideoMaxFrameDuration = target
            }
            device.unlockForConfiguration()
        }
        // Keep frames upright relative to gravity so face motion maps onto the screen.
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coordinator
        applyRotation(coordinator.videoRotationAngleForHorizonLevelCapture)
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] c, _ in
            let angle = c.videoRotationAngleForHorizonLevelCapture
            self?.sessionQueue.async { self?.applyRotation(angle) }
        }
        configured = true
        return true
    }

    private func applyRotation(_ angle: CGFloat) {
        guard let connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    private func report(_ new: Status) {
        guard new != status else { return }
        status = new
        let callback = onStatus
        DispatchQueue.main.async { callback?(new) }
    }

    // MARK: Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastProcessed >= 1.0 / 20.0, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastProcessed = now
        let request = VNDetectFaceRectanglesRequest()
        do {
            try sequenceHandler.perform([request], on: pixelBuffer, orientation: .up)
        } catch {
            return
        }
        guard let face = request.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }),
              face.confidence > 0.5 else {
            if now - lastSeen > 0.6 {
                lock.withLock { latest.valid = false }
                report(.searching)
            }
            return
        }
        lastSeen = now
        let box = face.boundingBox
        lock.withLock {
            latest = Pose(x: Float(box.midX), y: Float(box.midY), size: Float(box.width), timestamp: now, valid: true)
        }
        report(.tracking)
    }
}
