//
//  Theme.swift
//  ThreeDee
//
//  White / cobalt design language. "Paper" is cobalt ink on white; "Blueprint"
//  inverts it to white ink on cobalt. Every colour derives from those two.
//

import SwiftUI
import UIKit

enum Palette {
    /// Cobalt blue #0047AB.
    static let cobaltUI = UIColor(red: 0 / 255, green: 71 / 255, blue: 171 / 255, alpha: 1)
    static let deepCobaltUI = UIColor(red: 0 / 255, green: 46 / 255, blue: 115 / 255, alpha: 1)
    static let mistUI = UIColor(red: 236 / 255, green: 241 / 255, blue: 250 / 255, alpha: 1)

    private static func dynamic(paper: UIColor, blueprint: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? blueprint : paper })
    }

    /// Primary foreground: cobalt on paper, white on blueprint.
    static let ink = dynamic(paper: cobaltUI, blueprint: .white)
    /// Background.
    static let paper = dynamic(paper: .white, blueprint: cobaltUI)
    /// Slightly tinted background for grouped surfaces.
    static let surface = dynamic(paper: mistUI, blueprint: deepCobaltUI)
    static let inkSecondary = dynamic(paper: cobaltUI.withAlphaComponent(0.62), blueprint: UIColor.white.withAlphaComponent(0.7))
    static let inkTertiary = dynamic(paper: cobaltUI.withAlphaComponent(0.38), blueprint: UIColor.white.withAlphaComponent(0.45))
    static let hairline = dynamic(paper: cobaltUI.withAlphaComponent(0.16), blueprint: UIColor.white.withAlphaComponent(0.24))
    static let wash = dynamic(paper: cobaltUI.withAlphaComponent(0.06), blueprint: UIColor.white.withAlphaComponent(0.08))
    /// Foreground for content placed on a solid `ink` fill.
    static let onInk = dynamic(paper: .white, blueprint: cobaltUI)
}

enum Typography {
    static func display(_ size: CGFloat = 34) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    static func title(_ size: CGFloat = 20) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    static func body(_ size: CGFloat = 16) -> Font { .system(size: size, weight: .regular, design: .rounded) }
    static func label(_ size: CGFloat = 15) -> Font { .system(size: size, weight: .medium, design: .rounded) }
    /// Small uppercase, letter-spaced caption ("tech" labels).
    static func caps(_ size: CGFloat = 11) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    /// Monospaced read-outs for numbers and coordinates.
    static func mono(_ size: CGFloat = 12, weight: Font.Weight = .medium) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}

struct CapsLabel: View {
    let text: String
    var color: Color = Palette.inkSecondary
    var size: CGFloat = 11

    init(_ text: String, color: Color = Palette.inkSecondary, size: CGFloat = 11) {
        self.text = text
        self.color = color
        self.size = size
    }

    var body: some View {
        Text(text.uppercased())
            .font(Typography.caps(size))
            .tracking(1.4)
            .foregroundStyle(color)
    }
}

/// Primary filled button.
struct InkButtonStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.label(compact ? 14 : 16))
            .foregroundStyle(Palette.onInk)
            .padding(.horizontal, compact ? 14 : 20)
            .padding(.vertical, compact ? 9 : 14)
            .background(Capsule().fill(Palette.ink))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Secondary outlined button.
struct OutlineButtonStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.label(compact ? 14 : 16))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, compact ? 14 : 20)
            .padding(.vertical, compact ? 9 : 14)
            .background(Capsule().fill(Palette.paper))
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Round icon button used on floating chrome.
struct IconButton: View {
    let systemName: String
    var filled = false
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(filled ? Palette.onInk : Palette.ink)
                .frame(width: size, height: size)
                .background(Circle().fill(filled ? Palette.ink : Palette.paper.opacity(0.92)))
                .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: filled ? 0 : 1))
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
    }
}

/// A rounded panel with a hairline border, used for floating HUD elements.
struct Panel<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.paper.opacity(0.94)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }
}

/// Corner crop marks, a small technical-drawing flourish.
struct CropMarks: Shape {
    var length: CGFloat = 8
    func path(in r: CGRect) -> Path {
        var p = Path()
        for (corner, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                                 (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0)] {
            p.move(to: CGPoint(x: corner.x + dx * length, y: corner.y))
            p.addLine(to: corner)
            p.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * length))
        }
        return p
    }
}

/// Pill-shaped segmented control with a sliding ink indicator.
struct PillPicker<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var compact = false
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(Typography.label(compact ? 13 : 14))
                        .foregroundStyle(selected ? Palette.onInk : Palette.ink)
                        .padding(.horizontal, compact ? 11 : 14)
                        .padding(.vertical, compact ? 7 : 9)
                        .frame(maxWidth: .infinity)
                        .background {
                            if selected {
                                Capsule().fill(Palette.ink).matchedGeometryEffect(id: "pill", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Palette.wash))
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .sensoryFeedback(.selection, trigger: selection)
    }
}

struct FormatChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Typography.mono(10, weight: .semibold))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().strokeBorder(Palette.ink.opacity(0.5), lineWidth: 1))
    }
}
