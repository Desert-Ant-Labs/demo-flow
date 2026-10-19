import AppKit
import DesertAntUI
import SwiftUI

/// Port centers, as each card reports them, for drawing wires.
struct PortAnchors: PreferenceKey {
    static let defaultValue: [FlowSession.PortKey: Anchor<CGPoint>] = [:]
    static func reduce(value: inout [FlowSession.PortKey: Anchor<CGPoint>], nextValue: () -> [FlowSession.PortKey: Anchor<CGPoint>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// What a working step is doing, in words, or nil when it is not working.
@MainActor
func activity(_ s: StepState, model: ModelHub.State?, name: String = "the model") -> String? {
    switch model {
    case .downloading(let f) where f > 0 && f < 1: return "Downloading \(name), \(Int(f * 100))%"
    case .downloading: return "Downloading \(name)"
    case .preparing: return "Preparing \(name) for this Mac"
    default: break
    }
    if s.asking { return "Waiting for your answer" }
    if s.status == .running { return s.items > 1 ? "Item \(s.item) of \(s.items)" : "Working" }
    return nil
}

/// A step on the canvas or in the step list. Models get the brand's model
/// card in their color; every other step the gray card. Both have the same
/// heading: a small pill and small icons on top, then the name.
struct NodeCard<Ports: View>: View {
    let node: Node
    let def: StepDef
    var selected = false
    /// In the step list a card takes the column's width.
    var fills = false
    /// The width while its edge is being dragged.
    var resizing: CGFloat? = nil
    @ViewBuilder var ports: (Bool) -> Ports

    @Environment(\.flowActions) private var actions
    @Environment(\.flowSession) private var session
    @Environment(\.colorScheme) private var colorScheme
    @State private var back = false
    @State private var showInfo = false

    /// The brand's feature card is 412 wide with a 32 radius; a card here is
    /// narrower, so the radius scales with it.
    private let radius: CGFloat = 24

    var body: some View {
        let state = session?.engine.state(node.id) ?? StepState()
        let model = def.model.map { ModelHub.shared.state($0) }
        let colors = Theme.card(def)
        let inactive = state.status == .skipped || (state.status == .idle && !def.inputs.isEmpty && def.category != .input)

        VStack(alignment: .leading, spacing: 0) {
            header(colors.tag)
            VStack(alignment: .leading, spacing: 12) {
                ports(back || def.model == nil)
                if def.model != nil && !back {
                    modelWindow(state, model: model)
                } else if def.model != nil {
                    settings
                } else {
                    stepWindow(state, model: model)
                }
                StatusLine(def: def, state: state, model: model, keepsLine: !fills)
                    .font(.caption)
                    .padding(.horizontal, 2)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .foregroundStyle(colors.ink.opacity(inactive ? 0.55 : 1))
        .frame(width: fills ? nil : width(state), alignment: .leading)
        .frame(maxWidth: fills ? .infinity : nil, alignment: .leading)
        .background(colors.fill)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(selected || def.featured ? AnyShapeStyle(DA.Color.accent) : AnyShapeStyle(edge),
                              lineWidth: selected ? 2.5 : def.featured ? 1.5 : 1)
        }
        .overlay(alignment: .topTrailing) {
            if session?.dropTarget == node.id {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(DA.Color.accent, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                    .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(DA.Color.accent.opacity(0.08)))
                    .overlay {
                        Label("Drop to use your own", systemImage: "arrow.down.circle.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Capsule().fill(DA.Color.accent))
                    }
                    .allowsHitTesting(false)
            }
        }
        .shadow(color: .black.opacity(selected ? 0.16 : 0.07), radius: selected ? 22 : 14, y: selected ? 10 : 6)
        .animation(.snappy(duration: 0.25), value: state.status)
        .environment(\.colorScheme, def.model == nil ? colorScheme : (inkIsLight(colors.ink) ? .dark : .light))
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(actions.graph.name(of: node.id)), \(pill.lowercased())")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The brand card's hairline, light on a dark canvas so a dark card (Redact
    /// is the canvas's own forest) keeps its edge.
    private var edge: Color {
        colorScheme == .dark ? Theme.cream.opacity(0.12) : Color.black.opacity(0.1)
    }

    /// Cream ink means a dark card, and its controls should say so.
    private func inkIsLight(_ ink: Color) -> Bool {
        (NSColor(ink).usingColorSpace(.sRGB)?.brightnessComponent ?? 0) > 0.6
    }

    private func width(_ state: StepState) -> CGFloat {
        if let resizing { return resizing }
        if let w = node.params["w"]?.number { return w }
        if node.type == "view" {
            let mode = ValueKind(rawValue: node.params["as"]?.string ?? "auto") ?? .auto
            return max(360, (mode == .auto ? kind(of: state.inputs["value"]) : mode).width)
        }
        return def.width ?? FlowSession.cardSize.width
    }

    // MARK: Heading

    private func header(_ tag: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(pill)
                    .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                    .kerning(0.8)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(tag))
                Spacer(minLength: 4)
                if let model = def.model {
                    IconButton(symbol: "info", help: "About \(model.info.name)") { showInfo.toggle() }
                        .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                            // The window's appearance, not the card's: a dark card's
                            // white text is unreadable on a light popover.
                            ModelInfoView(model: model)
                                .foregroundStyle(Color.primary)
                                .tint(Color.accentColor)
                                .environment(\.colorScheme, colorScheme)
                        }
                    IconButton(symbol: back ? "checkmark" : "slider.horizontal.3", help: back ? "Show the card" : "Settings") {
                        withAnimation(.snappy(duration: 0.25)) { back.toggle() }
                    }
                }
                if selected {
                    IconButton(symbol: "xmark", help: "Remove") { actions.remove(node.id) }
                }
            }
            StepNameField(node: node)
                .font(.system(size: 22, weight: .semibold))
                .kerning(-0.6)
                .padding(.top, 6)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .help(def.description)
    }

    private var pill: String {
        if TriggerSteps.isTrigger(def.type) { return "Starts the flow" }
        guard let model = def.model else { return def.category.kind }
        return model.info.kind
    }

    // MARK: Windows

    /// Once a model has run, its result takes the photo's place.
    /// Running again keeps the last result where it is, dimmed under a small
    /// spinner, so the card does not shrink and grow with every run. Only a
    /// first run, or a model still downloading, shows the working box.
    @ViewBuilder private func modelWindow(_ state: StepState, model: ModelHub.State?) -> some View {
        let working = state.status == .running || model?.isWorking == true
        if state.outputs != nil, model?.isWorking != true, state.status == .running || state.status == .done {
            StepPreview(node: node, state: state)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.primary.opacity(0.07)))
                .opacity(working ? 0.45 : 1)
                .overlay(alignment: .topTrailing) {
                    if working { DA.Loader(.fillSpiral).frame(width: 18).padding(10) }
                }
        } else if working {
            Busy(state: state, model: model, name: def.model?.info.name ?? "the model")
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            StepBody(node: node)
            Text(def.model?.info.about ?? "")
                .font(.callout)
                .opacity(0.8)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func stepWindow(_ state: StepState, model: ModelHub.State?) -> some View {
        if StepBody.has(node.type) || StepPreview.has(node.type) {
            VStack(alignment: .leading, spacing: 10) {
                StepBody(node: node)
                if state.status == .done, StepPreview.has(node.type) {
                    StepPreview(node: node, state: state)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.window))
            .foregroundStyle(Color.primary)
        }
    }
}

/// A step's name in its card's heading, which a click edits. Cleared, it goes
/// back to the name it would have had.
struct StepNameField: View {
    let node: Node
    @Environment(\.flowActions) private var actions
    /// The name as it is typed, written to the flow once, when done.
    @State private var draft: String?
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: Binding(get: { draft ?? actions.graph.name(of: node.id) }, set: { draft = $0 }))
            .textFieldStyle(.plain)
            .lineLimit(1)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { if !focused { commit() } }
            .accessibilityLabel("Step name")
    }

    private func commit() {
        guard let typed = draft?.trimmingCharacters(in: .whitespaces) else { return }
        draft = nil
        let label: JSON = typed.isEmpty || typed == actions.graph.defaultName(of: node.id) ? .null : .string(typed)
        if label != (node.params["label"] ?? .null) { actions.set(node.id, ["label": label]) }
    }
}

/// A small round button in a card's top row.
struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.primary.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A working step's progress, in words and a track.
struct Busy: View {
    let state: StepState
    let model: ModelHub.State?
    var name = "the model"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                DA.Loader(.fillSpiral).frame(width: 22)
                Text(activity(state, model: model, name: name) ?? "Working").font(.callout.weight(.medium))
            }
            if model == .preparing {
                Text("Core ML tunes the model for this chip before its first run. After that it takes milliseconds.")
                    .font(.caption)
                    .opacity(0.75)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state.items > 1 {
                Track(fraction: Double(state.item) / Double(state.items))
            } else if case .downloading(let f) = model, f > 0 {
                Track(fraction: f)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.primary.opacity(0.08)))
    }
}

/// One line under a card: what it is doing, what went wrong, or how long it took.
struct StatusLine: View {
    let def: StepDef
    let state: StepState
    let model: ModelHub.State?
    /// On the canvas an empty line keeps the card from jumping as it runs.
    var keepsLine = true

    var body: some View {
        Group {
            if let doing = activity(state, model: model, name: def.model?.info.name ?? "the model") {
                Text(doing)
            } else if state.status == .error {
                Text(state.error ?? "Something went wrong").foregroundStyle(Theme.danger)
            } else if let note = state.note {
                Text(note)
            } else if case .failed(let reason) = model, let id = def.model {
                HStack(spacing: 6) {
                    Text(reason).foregroundStyle(Theme.danger)
                    Button("Try again") { ModelHub.shared.retry(id) }.buttonStyle(.link)
                }
            } else if state.status == .skipped {
                Text("Not taken")
            } else if state.status == .done, def.model != nil, let ms = state.ms {
                Text(done(ms))
            } else if state.status == .idle, !def.inputs.isEmpty {
                Text("Waiting for input")
            } else if keepsLine {
                Text(" ")
            }
        }
        .opacity(0.75)
        .lineLimit(state.status == .error ? 2 : 1)
    }

    private func done(_ ms: Double) -> AttributedString {
        var s = AttributedString()
        if let count = state.count, count > 1 { s += AttributedString("\(count) items in ") }
        var t = AttributedString(formatMs(ms))
        t.font = .caption.monospacedDigit()
        s += t
        s += AttributedString(" on this Mac")
        return s
    }
}

/// What a model is, how big, and where it is right now.
struct ModelInfoView: View {
    let model: ModelID

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.info.name).font(.headline)
            Text(model.info.about).fixedSize(horizontal: false, vertical: true)
            Text("\(size) · \(location)").font(.caption).foregroundStyle(Color.secondary)
            Link("About \(model.info.name), and how to use it in your app", destination: model.page).font(.callout)
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
    }

    private var size: String {
        model.info.mb >= 10 ? "\(Int(model.info.mb.rounded()))MB" : "\(model.info.mb.formatted())MB"
    }

    private var location: String {
        switch ModelHub.shared.state(model) {
        case .downloading(let f): "Downloading \(Int(f * 100))%"
        case .preparing: "Preparing for this Mac"
        case .ready: "Runs on this Mac. What it reads never leaves it."
        case .failed: "Couldn't load"
        case .idle: ModelHub.runner(model).isDownloaded() ? "Runs on this Mac. What it reads never leaves it." : "Downloads once, then runs on this Mac"
        }
    }
}

/// How far along, as a thin track in the card's ink, as on the web.
struct Track: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(.primary.opacity(0.12))
            .frame(height: 3)
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    Capsule().fill(.primary).frame(width: g.size.width * min(1, max(0, fraction)))
                }
            }
            .animation(.smooth, value: fraction)
    }
}
