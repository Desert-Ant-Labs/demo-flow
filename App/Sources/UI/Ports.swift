import DesertAntUI
import SwiftUI

/// A card's inputs and outputs on the canvas: a row each, with the dot a wire
/// attaches to at the card's edge.
struct PortsView: View {
    let node: Node
    let def: StepDef
    /// Whether to offer the outputs it is not giving yet.
    var extras = true
    @Environment(\.flowActions) private var actions
    @Environment(\.flowSession) private var session

    var body: some View {
        let wired = actions.graph.wiredFrom(node.id)
        let outs = def.visibleOutputs(node.params, wired: wired)
        let rows = max(def.inputs.count, outs.count)
        let on = Set(node.params["fields"]?.strings ?? def.pick?.defaults ?? [])
        if rows > 0 || extras {
            VStack(alignment: .leading, spacing: 6) {
                if rows > 0 {
                    HStack {
                        Text(def.inputs.isEmpty ? "" : "Uses")
                        Spacer()
                        Text(outs.isEmpty ? "" : "Gives")
                    }
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .textCase(.uppercase)
                    .opacity(0.6)
                }
                ForEach(0..<rows, id: \.self) { i in
                    HStack(spacing: 6) {
                        if i < def.inputs.count {
                            let input = def.inputs[i]
                            PortTag(text: input.label, dashed: input.optional)
                                .overlay(alignment: .leading) {
                                    PortDot(key: .init(node: node.id, port: input.id, output: false), type: input.type,
                                            label: "\(input.label), \(actions.graph.name(of: node.id))")
                                        .offset(x: -16 - 11)
                                }
                        }
                        Spacer(minLength: 8)
                        if i < outs.count {
                            let output = outs[i]
                            let removable = def.pick != nil && !wired.contains(output.id) && outs.count > 1
                            Group {
                                if removable {
                                    Button {
                                        let fields = def.outputs.map(\.id).filter { $0 != output.id && on.contains($0) }
                                        actions.set(node.id, ["fields": .array(fields.map { .string($0) })])
                                    } label: { PortTag(text: output.label, removable: true) }
                                    .buttonStyle(.plain)
                                    .help("Stop giving this output")
                                } else {
                                    PortTag(text: output.label)
                                }
                            }
                            .overlay(alignment: .trailing) {
                                PortDot(key: .init(node: node.id, port: output.id, output: true), type: output.type,
                                        label: "\(output.label), \(actions.graph.name(of: node.id))")
                                    .offset(x: 16 + 11)
                            }
                        }
                    }
                    .frame(minHeight: 22)
                }
                if extras { ExtraOutputs(node: node, def: def) }
                if def.category != .output && def.category != .note && !outs.isEmpty && wired.isEmpty {
                    Chip(text: "Show result", symbol: "plus") { actions.addAfter(node.id, outs[0].id, "view") }
                }
            }
        }
    }
}

struct PortTag: View {
    let text: String
    var dashed = false
    var removable = false

    var body: some View {
        HStack(spacing: 4) {
            Text(text).lineLimit(1)
            if removable { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).opacity(0.6) }
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(.primary.opacity(dashed ? 0.04 : 0.1)))
        .overlay { if dashed { Capsule().strokeBorder(.primary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 2])) } }
    }
}

struct Chip: View {
    let text: String
    var symbol: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
                Text(text)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(.primary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(0.8)
    }
}

/// Outputs a step can give but is not giving yet: dashed chips, one click to
/// add. A step with many (Eye) suggests a few and lists the rest by group.
struct ExtraOutputs: View {
    let node: Node
    let def: StepDef
    @Environment(\.flowActions) private var actions
    @State private var all = false

    var body: some View {
        if let pick = def.pick {
            let on = Set(node.params["fields"]?.strings ?? pick.defaults)
            let wired = actions.graph.wiredFrom(node.id)
            let extra = def.outputs.filter { !on.contains($0.id) && !wired.contains($0.id) }
            let add = { (id: String) in
                let fields = def.outputs.map(\.id).filter { $0 == id || on.contains($0) }
                actions.set(node.id, ["fields": .array(fields.map { .string($0) })])
            }
            if !extra.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Add").font(.callout).opacity(0.7)
                    VStack(alignment: .leading, spacing: 8) {
                        if pick.groups.isEmpty {
                            FlowRow { ForEach(extra) { o in Chip(text: o.label, symbol: "plus") { add(o.id) } } }
                        } else if all {
                            ForEach(pick.groups, id: \.0) { group, label in
                                let list = extra.filter { $0.group == group }
                                if !list.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(label).font(.caption).opacity(0.6)
                                        FlowRow { ForEach(list) { o in Chip(text: o.label, symbol: "plus") { add(o.id) } } }
                                    }
                                }
                            }
                            MoreButton(text: "Fewer") { all.toggle() }
                        } else {
                            FlowRow {
                                ForEach(extra.filter { pick.suggest.contains($0.id) }.prefix(3)) { o in Chip(text: o.label, symbol: "plus") { add(o.id) } }
                                MoreButton(text: "More…") { all.toggle() }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// A quiet button at chip size, for showing more or fewer chips.
private struct MoreButton: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(text, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .padding(.vertical, 3)
            .opacity(0.7)
    }
}

/// Lays its children out in rows, wrapping when a row is full.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews) {
            for (i, x) in row.items {
                subviews[i].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }

    private struct Row {
        var items: [(index: Int, x: CGFloat)] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (i, s) in subviews.enumerated() {
            let size = s.sizeThatFits(.unspecified)
            if !row.items.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row(y: row.y + row.height + spacing)
            }
            let x = row.items.isEmpty ? 0 : row.width + spacing
            row.items.append((i, x))
            row.width = x + size.width
            row.height = max(row.height, size.height)
        }
        rows.append(row)
        return rows
    }
}

/// The dot a wire attaches to. Dragging from an output draws a wire, and
/// letting go over an input connects them. Dragging from an input that has a
/// wire picks that wire up: let go over another input to move it there, or
/// anywhere else to take it out.
struct PortDot: View {
    let key: FlowSession.PortKey
    let type: PortType
    /// The step and port name, for VoiceOver.
    var label = ""
    @Environment(\.flowSession) private var session
    @Environment(\.flowActions) private var actions
    @State private var hover = false

    var body: some View {
        let fit = fits()
        let wire = wired
        Circle()
            .fill(Theme.wire(type))
            .overlay(Circle().strokeBorder(Theme.cream, lineWidth: 2))
            .frame(width: 13, height: 13)
            .overlay { if fit == true { Circle().strokeBorder(DA.Color.accent, lineWidth: 2).frame(width: 21, height: 21) } }
            .opacity(fit == false ? 0.2 : 1)
            .scaleEffect(hover || fit == true ? 1.35 : 1)
            .frame(width: 22, height: 22)
            .contentShape(Circle())
            .onHover { hover = $0 }
            .anchorPreference(key: PortAnchors.self, value: .center) { [key: $0] }
            .gesture(key.output || wire != nil ? drag : nil)
            .help(key.output ? "Drag to a step's input to connect" : wire != nil ? "Drag away to disconnect" : "")
            .accessibilityElement()
            .accessibilityLabel(key.output ? "Output \(label)" : "Input \(label)")
            .accessibilityValue(key.output ? "" : wire == nil ? "Not connected" : "Connected")
    }

    /// The wire into this input, if it has one.
    private var wired: Edge? {
        guard !key.output else { return nil }
        return actions.graph.edges.first { $0.target == key.node && $0.targetHandle == key.port }
    }

    /// For an input while a wire is drawn: whether that wire could end here.
    private func fits() -> Bool? {
        guard !key.output, let c = session?.connecting, c.from.node != key.node,
              let from = actions.graph.node(c.from.node), let out = from.def?.outputs.first(where: { $0.id == c.from.port }),
              let input = actions.graph.node(key.node)?.def?.inputs.first(where: { $0.id == key.port })
        else { return nil }
        return accepts(input, of: actions.graph.node(key.node)?.def, outputKind(from, out, session: session)) && out.type.fits(input.type)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("canvas"))
            .onChanged { g in
                guard let session else { return }
                let to = session.toCanvas(g.location)
                if session.connecting != nil {
                    session.connecting?.to = to
                } else if key.output {
                    session.connecting = .init(from: key, type: type, to: to)
                } else if let wire = wired {
                    let source = actions.graph.node(wire.source)?.def?.outputs.first { $0.id == wire.sourceHandle }?.type ?? .any
                    session.connecting = .init(from: .init(node: wire.source, port: wire.sourceHandle, output: true), type: source,
                                               to: to, lifting: wire)
                }
            }
            .onEnded { g in
                guard let session, let c = session.connecting else { return }
                defer { session.connecting = nil }
                // Ports are in the canvas's units; letting go counts within
                // the same distance on screen at any zoom.
                let at = session.toCanvas(g.location)
                let target = session.ports
                    .filter { !$0.key.output && $0.key.node != c.from.node }
                    .min { hypot($0.value.x - at.x, $0.value.y - at.y) < hypot($1.value.x - at.x, $1.value.y - at.y) }
                    .flatMap { hypot($0.value.x - at.x, $0.value.y - at.y) * session.zoom < 36 ? $0.key : nil }
                if let lifted = c.lifting {
                    if target == key { return }
                    guard let target else { return actions.change { $0.wire(lifted.target, lifted.targetHandle, from: nil) } }
                    guard let edge = connection(c.from, to: target, in: session) else { return }
                    actions.change { g in
                        g.wire(lifted.target, lifted.targetHandle, from: nil)
                        g.wire(edge.target, edge.targetHandle, from: "\(edge.source)::\(edge.sourceHandle)")
                    }
                } else if let target, let edge = connection(c.from, to: target, in: session) {
                    actions.wire(edge.target, edge.targetHandle, "\(edge.source)::\(edge.sourceHandle)")
                }
            }
    }

    /// The wire from an output to an input, or nil, with a word on why, when
    /// the input can't take it.
    private func connection(_ from: FlowSession.PortKey, to target: FlowSession.PortKey, in session: FlowSession) -> Edge? {
        let edge = Edge(source: from.node, sourceHandle: from.port, target: target.node, targetHandle: target.port)
        if let source = actions.graph.node(from.node), let out = source.def?.outputs.first(where: { $0.id == from.port }),
           let to = actions.graph.node(edge.target), let input = to.def?.inputs.first(where: { $0.id == edge.targetHandle }) {
            let kind = outputKind(source, out, session: session)
            guard accepts(input, of: to.def, kind) else {
                session.notify("\(out.label) gives \(kind.noun), and \(actions.graph.name(of: to.id)) needs \(Kind(input.type).noun)")
                return nil
            }
        }
        guard actions.graph.canConnect(edge) else {
            session.notify("Those two don't fit together")
            return nil
        }
        return edge
    }
}

/// An input's source in the step list: a menu of the outputs before it that fit.
struct SourcesView: View {
    let node: Node
    let before: [Node]

    var body: some View {
        let def = node.def!
        if !def.inputs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(def.inputs) { input in
                    HStack(spacing: 8) {
                        Text(input.label).font(.callout).opacity(0.7)
                        SourcePicker(node: node, input: input, before: before)
                    }
                }
            }
        }
    }
}

/// The menu that picks which earlier output feeds one input. The steps come
/// in order with their numbers, a step's outputs grouped under it, and an
/// input that still needs one says so.
struct SourcePicker: View {
    let node: Node
    let input: Port
    let before: [Node]
    /// Another input to show when this one is empty, as If's check shows
    /// the value it checks by default.
    var shows: String? = nil
    @Environment(\.flowActions) private var actions
    @Environment(\.flowSession) private var session
    @Environment(\.stepNumbers) private var numbers

    var body: some View {
        let own = actions.graph.edges.first { $0.target == node.id && $0.targetHandle == input.id }
        let edge = own ?? shows.flatMap { id in actions.graph.edges.first { $0.target == node.id && $0.targetHandle == id } }
        let current = edge.map { "\($0.source)::\($0.sourceHandle)" }
        let all = sources()
        let fitting = all.compactMap { $0.only(fits: true) }
        let other = all.compactMap { $0.only(fits: false) }
        let chosen = all.lazy.flatMap(\.outputs).first { $0.key == current }
        let optional = input.optional && shows == nil
        ChoiceMenu(empty: chosen == nil, required: !optional) {
            if let chosen, let group = all.first(where: { $0.outputs.contains { $0.key == chosen.key } }) {
                HStack(spacing: 6) {
                    if let n = group.number { StepNumber(n).padding(.leading, -7) }
                    Text(group.name)
                    if group.detailed {
                        Text("·").foregroundStyle(.tertiary)
                        Text(chosen.label).foregroundStyle(.secondary)
                    }
                    if !chosen.fits {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                    }
                }
                .help(chosen.fits ? "" : "This gives \(chosen.kind.noun), and \(input.label) needs \(Kind(input.type) == .text ? "running text" : Kind(input.type).noun)")
            } else {
                Text(optional ? "Nothing" : choosePrompt(input))
            }
        } content: {
            ForEach(fitting, id: \.id) { group in
                let title = (group.number.map { "\($0). " } ?? "") + group.name
                if !group.detailed {
                    choice(title, key: group.outputs[0].key, current: current)
                } else {
                    Section(title) {
                        ForEach(group.outputs, id: \.key) { choice($0.label, key: $0.key, current: current) }
                    }
                }
            }
            if fitting.isEmpty { Text("No step before this one gives \(Kind(input.type).noun)") }
            if !other.isEmpty {
                Divider()
                Section("Gives something else") {
                    ForEach(other, id: \.id) { group in
                        ForEach(group.outputs, id: \.key) { o in
                            let name = (group.number.map { "\($0). " } ?? "") + group.name + (group.detailed ? " · \(o.label)" : "")
                            Button("\(name): \(o.kind.noun)") {}.disabled(true)
                        }
                    }
                }
            }
            if optional || own != nil {
                Divider()
                choice(optional ? "Nothing" : "Clear", key: nil, current: current)
            }
        }
    }

    private func choice(_ title: String, key: String?, current: String?) -> some View {
        Toggle(title, isOn: Binding(
            get: { current == key },
            set: { _ in actions.wire(node.id, input.id, key) }
        ))
    }

    private struct Output {
        let key: String
        let label: String
        let kind: Kind
        let fits: Bool
    }

    private struct Group {
        let id: String
        let number: Int?
        let name: String
        let outputs: [Output]
        /// Names the output too: a step with several, or one that picks
        /// which of many it gives, as Eye does.
        let detailed: Bool

        /// The same step with only the outputs that fit, or only those that
        /// do not, or nil when none are left.
        func only(fits: Bool) -> Group? {
            let kept = outputs.filter { $0.fits == fits }
            return kept.isEmpty ? nil : Group(id: id, number: number, name: name, outputs: kept, detailed: detailed)
        }
    }

    /// Every step before this one and what each output gives, numbered as in
    /// the list, so two of the same step tell apart.
    private func sources() -> [Group] {
        return before.compactMap { n in
            guard let d = n.def else { return nil }
            let outs = d.visibleOutputs(n.params, wired: actions.graph.wiredFrom(n.id))
            guard !outs.isEmpty else { return nil }
            return Group(id: n.id, number: numbers[n.id], name: actions.graph.name(of: n.id),
                         outputs: outs.map { o in
                             let kind = outputKind(n, o, session: session)
                             return Output(key: "\(n.id)::\(o.id)", label: o.label, kind: kind, fits: accepts(input, of: node.def, kind) && o.type.fits(input.type))
                         },
                         detailed: outs.count > 1 || d.pick != nil)
        }
    }
}

/// A step's number, as on the rail, small enough for a menu.
struct StepNumber: View {
    let number: Int
    init(_ number: Int) { self.number = number }

    var body: some View {
        Text("\(number)")
            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            .frame(width: 18, height: 18)
            .background(Circle().fill(.primary.opacity(0.1)))
    }
}

/// A menu that looks like a choice in a sentence: a soft capsule when it is
/// set, and a dashed outline in gray when it still waits for one.
struct ChoiceMenu<Label: View, Content: View>: View {
    var empty = false
    /// Waiting for a choice is something to fix, not a setting.
    var required = false
    @ViewBuilder let label: () -> Label
    @ViewBuilder let content: () -> Content
    @State private var hover = false

    var body: some View {
        Menu(content: content) {
            HStack(spacing: 6) {
                label().lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.5)
            }
            .foregroundStyle(empty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(.primary.opacity(empty ? 0 : hover ? 0.12 : 0.07)))
            .overlay {
                if empty {
                    Capsule().strokeBorder(required ? AnyShapeStyle(DA.Color.accent) : AnyShapeStyle(.primary.opacity(0.3)),
                                           style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
            }
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hover = $0 }
    }
}
