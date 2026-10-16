import AppKit
import DesertAntUI
import SwiftUI

/// The Desert Ant mark, as Redactor draws it in its menu: a stem with three
/// pairs of legs.
struct AntMark: Shape {
    private static let box = CGRect(x: 9.5, y: 7.5, width: 21, height: 23)
    private static let parts = [
        CGRect(x: 17.9, y: 7.5, width: 4.2, height: 23),
        CGRect(x: 22.1, y: 16.72, width: 4.2, height: 4.43), CGRect(x: 13.7, y: 16.72, width: 4.2, height: 4.43),
        CGRect(x: 26.3, y: 12.43, width: 4.2, height: 4.42), CGRect(x: 9.5, y: 12.43, width: 4.2, height: 4.42),
        CGRect(x: 26.3, y: 21.15, width: 4.2, height: 4.42), CGRect(x: 9.5, y: 21.15, width: 4.2, height: 4.42),
    ]

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / Self.box.width, rect.height / Self.box.height)
        let x = rect.midX - Self.box.width * scale / 2, y = rect.midY - Self.box.height * scale / 2
        var path = Path()
        for part in Self.parts {
            path.addRect(CGRect(x: x + (part.minX - Self.box.minX) * scale, y: y + (part.minY - Self.box.minY) * scale,
                                width: part.width * scale, height: part.height * scale))
        }
        return path
    }

    /// The mark as a template image for the menu bar, 12 by 13 points.
    static let menuImage: NSImage = {
        let image = NSImage(size: NSSize(width: 12, height: 13), flipped: true) { rect in
            NSColor.black.setFill()
            AntMark().path(in: rect).cgPath.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

private extension CGPath {
    func fill() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.addPath(self)
        context.fillPath()
    }
}

extension Color {
    static let cream = DA.Color.cream
    static let ink = DA.Color.ink
    static let clayRed = DA.Color.clayRed
    static let sage = DA.Color.sage
    static let ember = DesignTokens.Colors.colorSignalWarning
    static let brandAccent = DA.Color.accent
}

/// The system glass button dims in a window that isn't key, and the
/// indicator and the menu never are, so this draws the same glass itself.
/// The same style as Redactor's.
struct GlassCapsuleButtonStyle: ButtonStyle {
    var tint: Color = .cream.opacity(0.14)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .tracking(-0.2)
            .foregroundStyle(Color.cream)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            // Glass alone washes a tint out to gray, so the color sits under it.
            .background(tint, in: .capsule)
            .glassEffect(.regular.interactive(), in: .capsule)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.smooth(duration: 0.15), value: configuration.isPressed)
    }
}

/// A round badge: a cream disc with an ink symbol, or another pair of colors.
struct Badge: View {
    let symbol: String
    var size: CGFloat = 32
    var disc: Color = .cream
    var ink: Color = .ink

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(ink)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: size, height: size)
            .background(disc, in: .circle)
    }
}

/// A quiet round button with a symbol, brighter under the pointer.
struct QuietButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.cream.opacity(hovering ? 0.95 : 0.55))
                .frame(width: 28, height: 28)
                .background(Color.cream.opacity(hovering ? 0.1 : 0), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A quiet word button, for the second action beside a glass one.
struct QuietTextButton: View {
    let title: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(Color.cream.opacity(hovering ? 0.95 : 0.6))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.cream.opacity(hovering ? 0.1 : 0), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// A ring that fills as a run goes, in cream on the dark glass.
struct ProgressRing: View {
    let progress: Double
    var size: CGFloat = 16
    var line: CGFloat = 2
    var color: Color = .cream

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: line)
            Circle()
                .trim(from: 0, to: max(0.03, progress))
                .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth(duration: 0.4), value: progress)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("\(Int(progress * 100)) percent")
    }
}

/// The panels are seldom key, and the app behind them stays active, so
/// without this the first click on a button would only focus the panel.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
