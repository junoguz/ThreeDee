//
//  ImmersionHUD.swift
//  ThreeDee
//
//  Chrome shown while standing inside a model: leave, parallax, VR toggle,
//  a walking joystick, colours, world scale and "back to start".
//

import simd
import SwiftUI

struct ImmersionHUD: View {
    let controller: ViewerController
    let parallaxEnabled: Bool
    let hasAppearance: Bool
    @Binding var colors: Bool
    let toggleParallax: () -> Void
    @State private var showHint = true

    var body: some View {
        Group {
            if controller.isVR { vrChrome } else { handheldChrome }
        }
        .task(id: controller.isVR) {
            showHint = true
            try? await Task.sleep(for: .seconds(controller.isVR ? 7 : 5))
            withAnimation(.easeOut(duration: 0.6)) { showHint = false }
        }
    }

    // MARK: Hand-held

    private var handheldChrome: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                IconButton(systemName: "xmark") { controller.exitImmersion() }
                    .accessibilityLabel("Leave immersion")
                Spacer(minLength: 8)
                HeadTrackingPill(status: controller.headStatus, enabled: parallaxEnabled, toggle: toggleParallax)
                VRToggle(active: false) { controller.setVR(true) }
            }
            if showHint {
                HintCard(lines: [("hand.draw", "Drag to look around"),
                                 ("circle.circle", "Joystick to walk"),
                                 ("hand.point.up.left.and.text", "Two fingers: step sideways · rise"),
                                 ("arrow.up.left.and.arrow.down.right", "Pinch to resize the world")])
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
            Spacer()
            HStack(alignment: .bottom) {
                Joystick { controller.setMove($0) }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Button { controller.resetWorldScale() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "figure.stand").font(.system(size: 12, weight: .semibold))
                            Text(controller.immersion.scaleLabel).font(Typography.mono(11, weight: .semibold))
                        }
                        .foregroundStyle(controller.immersion.isTrueScale ? Palette.ink : Palette.onInk)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Capsule().fill(controller.immersion.isTrueScale ? Palette.paper.opacity(0.94) : Palette.ink))
                        .overlay(Capsule().strokeBorder(Palette.hairline))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("World scale \(controller.immersion.scaleLabel). Tap to reset.")
                    HStack(spacing: 8) {
                        if hasAppearance {
                            ColorToggle(on: $colors)
                        }
                        IconButton(systemName: "scope", size: 40) { controller.resetView() }
                            .accessibilityLabel("Back to where you arrived")
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    // MARK: VR

    private var vrChrome: some View {
        VStack {
            HStack {
                VRToggle(active: true) { controller.setVR(false) }
                Spacer()
            }
            Spacer()
            if showHint {
                VStack(spacing: 4) {
                    Text("Place the phone in your headset")
                    Text(controller.motionAvailable ? "Look around to turn · hold the screen to walk" : "No motion sensors: drag to look · hold to walk")
                    Text("Double-tap to return to where you arrived")
                }
                .font(Typography.mono(11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.55)))
                .transition(.opacity)
            }
        }
        .padding(12)
    }
}

/// Small "VR" switch: filled while split-screen is on.
struct VRToggle: View {
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "visionpro").font(.system(size: 13, weight: .semibold))
                Text("VR").font(Typography.mono(12, weight: .bold))
            }
            .foregroundStyle(active ? Palette.onInk : Palette.ink)
            .padding(.horizontal, 12)
            .frame(height: active ? 36 : 44)
            .background(Capsule().fill(active ? Palette.ink : Palette.paper.opacity(0.94)))
            .overlay(Capsule().strokeBorder(Palette.hairline))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(active ? "Leave VR split screen" : "VR split screen for phone headsets")
    }
}

/// The original-colours switch used in the viewer's bottom bar and in immersion.
struct ColorToggle: View {
    @Binding var on: Bool

    var body: some View {
        Button { on.toggle() } label: {
            Image(systemName: on ? "paintpalette.fill" : "paintpalette")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(on ? Palette.onInk : Palette.ink)
                .frame(width: 40, height: 40)
                .background(Circle().fill(on ? Palette.ink : Palette.paper))
                .overlay(Circle().strokeBorder(Palette.hairline))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show original colours")
        .accessibilityValue(on ? "On" : "Off")
    }
}

private struct HintCard: View {
    let lines: [(icon: String, text: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(lines, id: \.text) { line in
                HStack(spacing: 8) {
                    Image(systemName: line.icon).font(.system(size: 11, weight: .semibold)).frame(width: 16)
                    Text(line.text).font(Typography.mono(11, weight: .medium))
                }
                .foregroundStyle(Palette.ink)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.paper.opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline))
        .allowsHitTesting(false)
    }
}

/// Walking joystick: push to move (forward/back, strafe). Small dead zone and a soft response
/// curve so creeping up to things is easy.
struct Joystick: View {
    var onChange: (SIMD2<Float>) -> Void
    @State private var knob = CGSize.zero
    @State private var active = false
    private let radius: CGFloat = 54
    private let knobSize: CGFloat = 46

    var body: some View {
        ZStack {
            Circle().fill(Palette.paper.opacity(0.9))
            Circle().strokeBorder(Palette.hairline, lineWidth: 1)
            Circle().strokeBorder(Palette.hairline, style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                .padding(radius * 0.42)
            ForEach(0..<4, id: \.self) { i in
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Palette.inkTertiary)
                    .offset(y: -radius + 11)
                    .rotationEffect(.degrees(Double(i) * 90))
            }
            Circle()
                .fill(Palette.ink)
                .frame(width: knobSize, height: knobSize)
                .overlay(Image(systemName: "figure.walk").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.onInk))
                .scaleEffect(active ? 1.06 : 1)
                .offset(knob)
        }
        .frame(width: radius * 2, height: radius * 2)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let reach = radius - knobSize / 2
                    var d = CGSize(width: v.location.x - radius, height: v.location.y - radius)
                    let length = hypot(d.width, d.height)
                    if length > reach { d.width *= reach / length; d.height *= reach / length }
                    knob = d
                    active = true
                    onChange(Joystick.response(SIMD2(Float(d.width / reach), Float(-d.height / reach))))
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { knob = .zero; active = false }
                    onChange(.zero)
                }
        )
        .sensoryFeedback(.impact(weight: .light), trigger: active) { _, now in now }
        .accessibilityLabel("Walk joystick")
    }

    static func response(_ v: SIMD2<Float>) -> SIMD2<Float> {
        let m = simd_length(v)
        let dead: Float = 0.12
        guard m > dead else { return .zero }
        let k = pow((min(m, 1) - dead) / (1 - dead), 1.5)
        return v / m * k
    }
}
