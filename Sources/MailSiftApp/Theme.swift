import AppKit
import SwiftUI

/// Monochrome palette. Ink and paper swap in dark mode, so everything is built from these two plus opacities.
enum Theme {
    static let ink = Color.primary
    static let paper = Color(nsColor: .windowBackgroundColor)
    static let canvas = Color(nsColor: .textBackgroundColor)
    static let muted = Color.primary.opacity(0.52)
    static let faint = Color.primary.opacity(0.32)
    static let hairline = Color.primary.opacity(0.09)
    static let fill = Color.primary.opacity(0.045)
    static let hover = Color.primary.opacity(0.07)
    static let selected = Color.primary.opacity(0.09)

    static let radius: CGFloat = 8
    static let railWidth: CGFloat = 196
}

extension View {
    func hairlineBorder(_ radius: CGFloat = Theme.radius) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.hairline))
    }
}

/// Solid ink button (white on black in light mode).
struct InkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.paper)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Theme.ink.opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.25),
                        in: RoundedRectangle(cornerRadius: Theme.radius))
    }
}

/// Outlined button.
struct LineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.ink.opacity(enabled ? 1 : 0.35))
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(configuration.isPressed ? Theme.hover : Color.clear, in: RoundedRectangle(cornerRadius: Theme.radius))
            .hairlineBorder()
    }
}

/// Square icon button with a hover fill, for toolbars.
struct IconButton: View {
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(active ? Theme.paper : Theme.ink)
                .frame(width: 30, height: 30)
                .background(active ? Theme.ink : (hovering ? Theme.hover : .clear),
                            in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Thin determinate bar.
struct ThinProgress: View {
    let value: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline)
                Capsule().fill(Theme.ink).frame(width: max(0, min(1, value)) * g.size.width)
            }
        }
        .frame(height: 3)
    }
}

/// Black circle with the sender's initial.
struct Monogram: View {
    let name: String
    var size: CGFloat = 34

    var body: some View {
        Text(String(name.trimmingCharacters(in: .whitespaces).first ?? "?").uppercased())
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(Theme.paper)
            .frame(width: size, height: size)
            .background(Theme.ink, in: Circle())
    }
}

/// Small uppercase-style section label.
struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.muted)
    }
}
