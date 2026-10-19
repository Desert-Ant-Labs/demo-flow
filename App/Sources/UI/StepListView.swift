import AppKit
import DesertAntUI
import SwiftUI
import UniformTypeIdentifiers

/// The flow as an ordered list of steps: the same steps and wires, with each
/// input choosing its source from a menu instead of a dragged wire. A numbered
/// rail down the left joins each step to the next. Split and Merge read as a
/// line between the steps, and the steps on its If and Else sides sit
/// indented under it.
struct StepListView: View {
    @Binding var graph: Graph
    let session: FlowSession
    @Environment(\.flowActions) private var actions

    var body: some View {
        let ordered = graph.ordered.filter { $0.type != "note" }
        let notes = graph.nodes.filter { $0.type == "note" && !($0.params["text"]?.string ?? "").isEmpty }
        let rows = StepRows(graph: graph, ordered: ordered).rows
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    FlowHeader(graph: $graph)
                        .padding(.leading, StepRail.width)
                        .padding(.bottom, 28)
                    ForEach(notes) { note in
                        Text(note.params["text"]?.string ?? "")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.leading, StepRail.width)
                            .padding(.bottom, 20)
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                        HStack(alignment: .top, spacing: 0) {
                            StepRail(number: row.number, symbol: row.symbol, first: i == 0, last: i == rows.count - 1, id: row.movable)
                            BranchGuides(guides: row.guides)
                            content(row, before: before(row, ordered))
                        }
                        .overlay(alignment: .bottomLeading) {
                            if let gap = gap(after: row, next: i + 1 < rows.count ? rows[i + 1] : nil) {
                                InsertGap { session.palette = gap } drop: { id in
                                    if let after = gap.after { actions.move(id, after, gap.before) }
                                }
                            }
                        }
                        .id(row.id)
                    }
                    Color.clear.frame(height: 40)
                }
                .environment(\.stepNumbers, StepRows.numbers(of: rows))
                .frame(maxWidth: 680)
                .padding(.horizontal, 32)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity)
                .background(Color.clear.contentShape(Rectangle()).onTapGesture { endEditing() })
            }
            .onChange(of: session.reveal, initial: true) { _, id in
                guard let id else { return }
                withAnimation { scroll.scrollTo(id, anchor: .center) }
                session.reveal = nil
            }
        }
        .background(Theme.canvas)
    }

    @ViewBuilder
    private func content(_ row: StepRows.Row, before: [Node]) -> some View {
        switch row.kind {
        case .step(let node):
            if let def = node.def {
                let selected = session.selection.contains(node.id)
                Group {
                    if LogicLine.has(node.type) {
                        LogicLine(node: node, selected: selected)
                            .padding(.bottom, 22)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            NodeCard(node: node, def: def, selected: selected, fills: true) { _ in
                                if !def.inputs.isEmpty || def.pick != nil {
                                    VStack(alignment: .leading, spacing: 10) {
                                        SourcesView(node: node, before: before)
                                        ExtraOutputs(node: node, def: def)
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 24)
                    }
                }
                .onTapGesture { endEditing(); session.selection = [node.id] }
            }
        case .side(let ifID, let yes, let empty):
            let add = { session.palette = .init(after: (ifID, yes ? "yes" : "no")) }
            Group {
                if let ask = graph.node(ifID), ask.type == "ask" {
                    AskSide(node: ask, yes: yes, empty: empty, add: add)
                } else if yes, let ifNode = graph.node(ifID) {
                    IfCondition(node: ifNode, before: nodes(before: ifID), empty: empty, add: add)
                } else {
                    ElseLabel(empty: empty, add: add, elseIf: { actions.elseIf(ifID) })
                }
            }
            .padding(.bottom, empty ? 18 : 12)
        }
    }

    /// What adding a step below `row` means: which output it takes, and
    /// which step below took that output until now. Nothing goes between a
    /// Split and its If side, which has its own button.
    private func gap(after row: StepRows.Row, next: StepRows.Row?) -> FlowSession.PaletteRequest? {
        let source: String, output: String
        switch row.kind {
        case .side(let id, let yes, let empty):
            guard !empty else { return nil }
            (source, output) = (id, yes ? "yes" : "no")
        case .step(let node):
            guard !StepRows.isBranch(node.type), let def = node.def else { return nil }
            var taken: String?
            if case .step(let below)? = next?.kind {
                taken = graph.incoming(below.id).first { $0.source == node.id }?.sourceHandle
            }
            guard let first = taken ?? def.visibleOutputs(node.params, wired: graph.wiredFrom(node.id)).first?.id else { return nil }
            (source, output) = (node.id, first)
        }
        var request = FlowSession.PaletteRequest(after: (source, output))
        if case .step(let below)? = next?.kind,
           graph.incoming(below.id).contains(where: { $0.source == source && $0.sourceHandle == output }) {
            request.before = below.id
        }
        return request
    }

    /// What a step may take from: everything that runs before it.
    private func nodes(before id: String, in ordered: [Node]? = nil) -> [Node] {
        let ordered = ordered ?? graph.ordered.filter { $0.type != "note" }
        guard let i = ordered.firstIndex(where: { $0.id == id }) else { return [] }
        return Array(ordered.prefix(i))
    }

    private func before(_ row: StepRows.Row, _ ordered: [Node]) -> [Node] {
        row.stepID.map { nodes(before: $0, in: ordered) } ?? []
    }
}

/// The step list's rows, in reading order: each Split followed by its If side
/// and its Else side, each side indented one step further than the Split.
struct StepRows {
    /// Something steps sit inside: the If or Else side of a Split.
    struct Scope: Hashable {
        let ifID: String
        let yes: Bool

        static func side(ifID: String, yes: Bool) -> Scope { Scope(ifID: ifID, yes: yes) }
    }

    /// How a row draws the guide line of one scope it sits in.
    enum Guide: Hashable {
        case through(Scope)
        case starts(Scope)
    }

    enum Kind {
        case step(Node)
        /// The heading of one side of an If, and whether nothing is on it yet.
        case side(String, yes: Bool, empty: Bool)
    }

    struct Row: Identifiable {
        var kind: Kind
        var guides: [Guide]
        var number: Int?
        var symbol: String?

        var stepID: String? {
            if case .step(let n) = kind { n.id } else { nil }
        }

        /// The step its number or symbol drags, when it can be moved. A Merge
        /// stays where its two sides meet.
        var movable: String? {
            if case .step(let n) = kind, n.type != "merge" { n.id } else { nil }
        }

        var id: String {
            switch kind {
            case .step(let n): n.id
            case .side(let id, let yes, _): "\(id).\(yes ? "if" : "else")"
            }
        }
    }

    let rows: [Row]

    /// Steps whose Yes and No sides sit indented under them: Split and Ask.
    static func isBranch(_ type: String) -> Bool { type == "if" || type == "ask" }

    /// Each step's number, by its id. Split and Merge have none.
    static func numbers(of rows: [Row]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            if case .step(let n) = row.kind, let number = row.number { (n.id, number) } else { nil }
        })
    }

    init(graph: Graph, ordered: [Node]) {
        // The sides of Ifs a step sits on, outermost first. A step is on the
        // side of whatever it takes from that is deepest in, and where its
        // inputs come from both sides, as at a Merge, it is past that If.
        var path: [String: [Scope]] = [:]
        for node in ordered {
            var found: [Scope]?
            for edge in graph.incoming(node.id) {
                guard let source = graph.node(edge.source) else { continue }
                var p = path[edge.source] ?? []
                if Self.isBranch(source.type), edge.sourceHandle == "yes" || edge.sourceHandle == "no" {
                    p.append(.side(ifID: source.id, yes: edge.sourceHandle == "yes"))
                }
                guard let current = found else { found = p; continue }
                if current.starts(with: p) { continue }
                if p.starts(with: current) { found = p; continue }
                found = Array(zip(current, p).prefix { $0 == $1 }.map(\.0))
            }
            path[node.id] = found ?? []
        }

        var rows: [Row] = []
        var number = 0
        func guides(_ at: [Scope], last: (Scope) -> Guide = Guide.through) -> [Guide] {
            at.enumerated().map { i, s in i == at.count - 1 ? last(s) : .through(s) }
        }
        func emit(_ at: [Scope]) {
            for node in ordered where path[node.id] == at {
                let logic = LogicLine.has(node.type)
                if !logic { number += 1 }
                rows.append(Row(kind: .step(node), guides: guides(at), number: logic ? nil : number,
                                symbol: logic ? symbol(for: node.type) : nil))
                if Self.isBranch(node.type) {
                    for yes in [true, false] {
                        let side = at + [.side(ifID: node.id, yes: yes)]
                        let empty = !graph.edges.contains { $0.source == node.id && $0.sourceHandle == (yes ? "yes" : "no") }
                        rows.append(Row(kind: .side(node.id, yes: yes, empty: empty), guides: guides(side, last: Guide.starts)))
                        emit(side)
                    }
                }
            }
        }
        emit([])
        let shown = Set(rows.compactMap(\.stepID))
        for node in ordered where !shown.contains(node.id) {
            number += 1
            rows.append(Row(kind: .step(node), guides: [], number: number))
        }
        self.rows = rows
    }
}

/// The space between two rows: hovering it shows a plus on the rail, and
/// clicking adds a step there.
struct InsertGap: View {
    let add: () -> Void
    /// A step dragged here by its number moves here.
    var drop: ((String) -> Void)? = nil
    @State private var hover = false
    @State private var targeted = false

    var body: some View {
        Button(action: add) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(DA.Color.accent))
                    .padding(.leading, 4)
                Rectangle().fill(DA.Color.accent.opacity(0.5)).frame(height: 1.5)
                Text(targeted ? "Move it here" : "Add a step here").font(.caption.weight(.medium)).foregroundStyle(DA.Color.accent)
            }
            .opacity(hover || targeted ? 1 : 0)
            .frame(height: 22)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.snappy(duration: 0.15)) { hover = h } }
        .help("Add a step here")
        .dropDestination(for: StepReference.self) { steps, _ in
            guard let id = steps.first?.id, let drop else { return false }
            drop(id)
            return true
        } isTargeted: { t in withAnimation(.snappy(duration: 0.15)) { targeted = t } }
    }
}

/// A step's number, with the line down to the next step.
struct StepRail: View {
    static let width: CGFloat = 52
    /// How far each side of an If sits in.
    static let indent: CGFloat = 28
    var number: Int?
    /// For a line rather than a step: its symbol in place of a number.
    var symbol: String?
    var first = false
    let last: Bool
    /// The step, so its number or symbol can be dragged to move it.
    var id: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            line.frame(height: number != nil ? 14 : symbol != nil ? 8 : 0).opacity(first ? 0 : 1)
            Group {
                if let number {
                    Text("\(number)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Theme.canvas))
                        .background(Circle().fill(.primary.opacity(0.06)))
                        .overlay(Circle().strokeBorder(Theme.hairline))
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.canvas).rotationEffect(.degrees(45)).scaleEffect(0.8))
                        .background(RoundedRectangle(cornerRadius: 7).fill(.primary.opacity(0.06)).rotationEffect(.degrees(45)).scaleEffect(0.8))
                }
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(number.map { "Step \($0)" } ?? "")
            .accessibilityHidden(number == nil)
            .modifier(DragToMove(id: id))
            line.frame(maxHeight: .infinity).opacity(last ? 0 : 1)
        }
        .frame(width: 28)
        .frame(width: StepRail.width, alignment: .leading)
    }

    private var line: some View {
        Rectangle().fill(Theme.hairline).frame(width: 1.5)
    }
}

/// The guide lines of the sides of Ifs a row sits on: a line per side,
/// running the row's height. A side's heading starts its line.
struct BranchGuides: View {
    let guides: [StepRows.Guide]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(guides.enumerated()), id: \.offset) { _, guide in
                let color = Theme.hairline
                Group {
                    switch guide {
                    case .through:
                        Rectangle().fill(color).frame(width: 2)
                    case .starts:
                        VStack(spacing: 0) {
                            Color.clear.frame(height: 9)
                            Circle().fill(color).frame(width: 8, height: 8)
                            Rectangle().fill(color).frame(width: 2)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .frame(width: 14)
                .frame(width: StepRail.indent, alignment: .leading)
            }
        }
    }
}

/// The flow's title and description, editable in place, and the models it runs.
struct FlowHeader: View {
    @Binding var graph: Graph

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            BalancedField(prompt: graph.autoTitle, text: $graph.meta.title)
                .font(.largeTitle.weight(.bold))
            TextField("Say what this flow does", text: $graph.meta.description, axis: .vertical)
                .font(.title3)
                .foregroundStyle(.secondary)
                .textFieldStyle(.plain)
            if !graph.nodes.isEmpty { FlowModels(models: graph.models) }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }
}

/// One line naming the models a flow runs, each linking to its page.
struct FlowModels: View {
    let models: [ModelID]

    var body: some View {
        var text = AttributedString("Runs on this Mac")
        if !models.isEmpty {
            text += AttributedString(" with ")
            for (i, m) in models.enumerated() {
                if i > 0 { text += AttributedString(i < models.count - 1 ? ", " : models.count > 2 ? ", and " : " and ") }
                var name = AttributedString(m.info.name)
                name.link = m.page
                name.underlineStyle = .single
                text += name
            }
        }
        text += AttributedString(". Your recordings, text, and photos never leave it.")
        return Text(text).font(.callout).foregroundStyle(.secondary).tint(.secondary)
    }
}

extension EnvironmentValues {
    /// The step list's numbers, so each source menu names steps as the list does.
    @Entry var stepNumbers: [String: Int] = [:]
}

/// Takes the text cursor out of whatever field has it.
@MainActor func endEditing() {
    NSApp.keyWindow?.makeFirstResponder(nil)
}

/// Lets a step's number be picked up and dropped between two other steps.
struct DragToMove: ViewModifier {
    let id: String?

    func body(content: Content) -> some View {
        if let id {
            content
                .pointerStyle(.grabIdle)
                .draggable(StepReference(id: id))
                .help("Drag to move this step")
        } else {
            content
        }
    }
}

/// A step being dragged to a new place in the list. Its own type, so a gap
/// takes only a step and not any text dropped on it.
struct StepReference: Codable, Transferable {
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .flowStep)
    }
}

extension UTType {
    static let flowStep = UTType(exportedAs: "com.desertant.flow.step")
}
