import AppKit
import DesertAntUI
import SwiftUI

/// Whether a flow that starts with a trigger is on, and how it last went.
struct AutoState {
    var on: Bool
    /// The last run: "2 photos, 5 minutes ago".
    var last: String?
    var failed = false

    @MainActor init(path: String?) {
        let center = TriggerCenter.shared
        on = path.map(center.isOn) ?? false
        let record = center.history.first { r in path != nil && r.flow == path }
        last = record.map { "\($0.summary), \($0.date.formatted(.relative(presentation: .named)))" }
        failed = record?.failed ?? false
    }

    init(on: Bool, last: String?, failed: Bool = false) {
        self.on = on
        self.last = last
        self.failed = failed
    }
}

/// A flow in the Library: its title, a line on it, and the models it runs.
/// A flow that runs on its own takes the color of its first model and says
/// whether it is on; one that is off is quieter.
struct FlowCard: View {
    let title: String
    let detail: String
    let models: [ModelID]
    var state: AutoState?
    let open: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var hover = false

    var body: some View {
        let colors = Palette(models: state == nil ? [] : models)
        let dim = state.map { !$0.on } ?? false
        Button(action: open) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Balanced {
                        Text(title).hidden()
                        Text(title).lineLimit(2)
                    }
                    .font(.system(size: 13.5, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if state != nil {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .opacity(0.7)
                            .help("Runs on its own when it is on")
                    }
                }
                Text(detail)
                    .font(.caption)
                    .opacity(0.7)
                    .lineLimit(2, reservesSpace: true)
                Spacer(minLength: 0)
                if let state { AutoStatus(state: state) }
                ModelNames(models: models)
            }
            .opacity(dim ? 0.62 : 1)
            .foregroundStyle(colors.ink)
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(colors.fill))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(hover ? AnyShapeStyle(colors.branded ? colors.ink.opacity(0.5) : DA.Color.accent) : AnyShapeStyle(Theme.hairline),
                                  lineWidth: hover ? 1.5 : 1)
            }
            .environment(\.colorScheme, colors.scheme(colorScheme))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.snappy(duration: 0.15)) { hover = h } }
    }

    /// The card's colors: its first model's, or the plain card's.
    struct Palette {
        let fill: Color
        let ink: Color
        let branded: Bool

        init(models: [ModelID]) {
            if let first = models.first {
                let card = Theme.model(first)
                (fill, ink, branded) = (card.fill, card.ink, true)
            } else {
                (fill, ink, branded) = (Theme.stepFill, Color.primary, false)
            }
        }

        /// Cream ink means a dark card, and its controls should say so. A
        /// plain card follows the window.
        func scheme(_ window: ColorScheme) -> ColorScheme {
            guard branded else { return window }
            return (NSColor(ink).usingColorSpace(.sRGB)?.brightnessComponent ?? 0) > 0.6 ? .dark : .light
        }
    }
}

/// "On · 2 photos, 5 minutes ago", or "Off".
private struct AutoStatus: View {
    let state: AutoState

    var body: some View {
        HStack(spacing: 6) {
            StateDot(on: state.on, failed: state.failed)
            Text(state.on ? (state.last.map { "On · \($0)" } ?? "On, waiting") : "Off")
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
    }
}

/// Every card color, on and off, for checking them side by side:
/// FLOW_SHOW=card-colors.
@MainActor
enum CardColors {
    private static var window: NSWindow?

    static func show() {
        let sheet = VStack(alignment: .leading, spacing: 10) {
            ForEach([true, false], id: \.self) { on in
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(200), spacing: 10), count: 6), spacing: 10) {
                    ForEach([ModelID?.none] + ModelID.allCases.map(Optional.some), id: \.self) { model in
                        FlowCard(title: model?.info.name ?? "Plain", detail: "Runs on its own when files arrive.",
                                 models: model.map { [$0] } ?? [],
                                 state: AutoState(on: on, last: on ? "2 photos, 5 minutes ago" : nil)) {}
                    }
                }
            }
        }
        .padding(20)
        .background(Theme.canvas)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1300, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Card colors"
        window.contentView = NSHostingView(rootView: sheet)
        window.setContentSize(window.contentView?.fittingSize ?? .zero)
        window.orderFrontRegardless()
        self.window = window
    }
}
