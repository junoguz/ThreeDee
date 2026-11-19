//
//  ViewerCanvas.swift
//  ThreeDee
//
//  SwiftUI host for the Metal viewer. Gestures: one finger orbits, two fingers
//  pan, pinch zooms, double tap re-frames. In immersion: one finger looks
//  around (the view turns the way you drag), two fingers strafe / rise, pinch
//  resizes the world, double tap returns to where you arrived; in VR, holding
//  the screen (the headset's button) walks where you look.
//

import MetalKit
import Observation
import SwiftUI
import UIKit

/// Commands and live status shared between the SwiftUI HUD and the renderer.
@Observable
final class ViewerController {
    @ObservationIgnored weak var renderer: ViewerRenderer?
    @ObservationIgnored private var tracker: FaceTracker?
    @ObservationIgnored private let motion = HeadMotion()
    private(set) var headStatus: FaceTracker.Status = .idle
    private(set) var isImmersive = false
    private(set) var isVR = false
    private(set) var immersion = ImmersionStatus()

    var motionAvailable: Bool { motion.isAvailable }

    func resetView() { renderer?.resetView(animated: true) }

    func look(_ preset: ViewPreset) { renderer?.look(yaw: preset.yaw, pitch: preset.pitch) }

    // MARK: Immersion

    func enterImmersion() {
        guard let renderer, !isImmersive else { return }
        renderer.enterImmersion()
        isImmersive = renderer.isImmersive
    }

    func exitImmersion() {
        setVR(false)
        renderer?.exitImmersion()
        isImmersive = false
    }

    func setVR(_ on: Bool) {
        guard on != isVR, !on || isImmersive else { return }
        renderer?.headMotion = motion
        renderer?.setStereo(on)
        isVR = renderer?.isStereo ?? false
    }

    /// Joystick deflection: x strafes right, y walks forward (−1…1).
    func setMove(_ v: SIMD2<Float>) { renderer?.moveInput = v }

    func resetWorldScale() { renderer?.resetWorldScale() }

    func setHeadTracking(_ enabled: Bool) {
        if enabled {
            if tracker == nil {
                let t = FaceTracker()
                t.onStatus = { [weak self] status in
                    guard let controller = self else { return }
                    Task { @MainActor in controller.headStatus = status }
                }
                tracker = t
            }
            renderer?.faceTracker = tracker
            tracker?.start()
        } else {
            tracker?.stop()
            renderer?.faceTracker = nil
            headStatus = .idle
        }
    }

    func attach(_ renderer: ViewerRenderer) {
        self.renderer = renderer
        renderer.faceTracker = tracker
        renderer.headMotion = motion
        renderer.onImmersionChange = { [weak self] status in
            guard let self, self.immersion != status else { return }
            self.immersion = status
        }
    }

    deinit {
        tracker?.stop()
        motion.stop()
    }
}

enum ViewPreset: String, CaseIterable, Identifiable {
    case iso, top, front, right
    var id: String { rawValue }
    var title: String {
        switch self {
        case .iso: "ISO"
        case .top: "TOP"
        case .front: "FRONT"
        case .right: "RIGHT"
        }
    }
    var yaw: Float {
        switch self {
        case .iso: OrbitCamera.homeYaw
        case .top: -.pi / 2
        case .front: -.pi / 2
        case .right: 0
        }
    }
    var pitch: Float {
        switch self {
        case .iso: OrbitCamera.homePitch
        case .top: 1.5
        case .front, .right: 0
        }
    }
}

struct ViewerCanvas: UIViewRepresentable {
    let prepared: PreparedMesh?
    let style: ViewerStyle
    let controller: ViewerController

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero)
        view.isMultipleTouchEnabled = true
        if let renderer = ViewerRenderer(view: view) {
            context.coordinator.renderer = renderer
            renderer.style = style
            renderer.setContent(prepared)
            context.coordinator.contentID = prepared?.id
            controller.attach(renderer)
        }
        context.coordinator.install(on: view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        guard let renderer = context.coordinator.renderer else { return }
        if renderer.style != style { renderer.style = style }
        let id = prepared?.id
        if id != context.coordinator.contentID {
            context.coordinator.contentID = id
            renderer.setContent(prepared)
        }
        if controller.renderer !== renderer { controller.attach(renderer) }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var renderer: ViewerRenderer?
        var contentID: UUID?
        private var lastPan = CGPoint.zero
        private var lastTwoFinger = CGPoint.zero
        private var lastPinch: CGFloat = 1

        func install(on view: UIView) {
            let rotate = UIPanGestureRecognizer(target: self, action: #selector(handleRotate(_:)))
            rotate.minimumNumberOfTouches = 1
            rotate.maximumNumberOfTouches = 1
            rotate.delegate = self
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.minimumNumberOfTouches = 2
            pan.maximumNumberOfTouches = 2
            pan.delegate = self
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinch.delegate = self
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            let touchDown = UILongPressGestureRecognizer(target: self, action: #selector(handleTouchDown(_:)))
            touchDown.minimumPressDuration = 0
            touchDown.cancelsTouchesInView = false
            touchDown.delegate = self
            [rotate, pan, pinch, doubleTap, touchDown].forEach(view.addGestureRecognizer)
        }

        @objc private func handleTouchDown(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began:
                renderer?.stopInertia()
                renderer?.touchHeld = true
            case .ended, .cancelled, .failed:
                renderer?.touchHeld = false
            default:
                break
            }
        }

        @objc private func handleRotate(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            switch g.state {
            case .began:
                lastPan = t
            case .changed:
                renderer?.rotate(by: CGPoint(x: t.x - lastPan.x, y: t.y - lastPan.y))
                lastPan = t
            case .ended:
                renderer?.endRotate(velocity: g.velocity(in: g.view))
            default:
                break
            }
        }

        @objc private func handlePan(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            switch g.state {
            case .began: lastTwoFinger = t
            case .changed:
                renderer?.pan(by: CGPoint(x: t.x - lastTwoFinger.x, y: t.y - lastTwoFinger.y))
                lastTwoFinger = t
            default: break
            }
        }

        @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
            switch g.state {
            case .began: lastPinch = g.scale
            case .changed:
                renderer?.zoom(by: g.scale / max(lastPinch, 1e-3))
                lastPinch = g.scale
            default: break
            }
        }

        @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
            renderer?.resetView(animated: true)
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Two-finger pan and pinch work together; the touch-down observer coexists with everything.
            if g is UILongPressGestureRecognizer || other is UILongPressGestureRecognizer { return true }
            let pair = [g, other]
            return pair.contains { $0 is UIPinchGestureRecognizer } &&
                pair.contains { ($0 as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2 }
        }
    }
}
