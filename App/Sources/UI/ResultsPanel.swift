import SwiftUI

/// The answer, always in view: every step that ends the flow, large, beside
/// the canvas however it is panned or zoomed.
struct ResultsPanel: View {
    let graph: Graph
    let session: FlowSession
    var onFind: (Node) -> Void

    var body: some View {
        let feeds = Set(graph.edges.map(\.source))
        let results = graph.nodes.filter { n in
            guard let d = n.def, n.type != "note", d.category != .input else { return false }
            return d.category == .output || !feeds.contains(n.id)
        }
        .sorted { ($0.def?.category == .output ? 0 : 1) < ($1.def?.category == .output ? 0 : 1) }
        let names = graph.names()
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let path = session.fileURL?.path, Trigger.node(of: graph) != nil {
                    RunHistory(path: path)
                }
                if results.isEmpty {
                    Text("Add a Result step to see the answer here.").foregroundStyle(.secondary)
                }
                ForEach(results) { n in
                    if let def = n.def { ResultSection(node: n, def: def, name: names[n.id] ?? def.title, state: session.engine.state(n.id), onFind: { onFind(n) }) }
                }
            }
            .padding(16)
        }
        .background(Theme.canvas)
    }
}

struct ResultSection: View {
    let node: Node
    let def: StepDef
    /// What the step is called in the flow, the same as on its card.
    let name: String
    let state: StepState
    var onFind: () -> Void
    @State private var open: Bool?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isOpen = open ?? (def.category == .output)
        let model = def.model.map { ModelHub.shared.state($0) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { withAnimation(reduceMotion ? nil : .snappy) { open = !isOpen } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right").rotationEffect(.degrees(isOpen ? 90 : 0)).font(.caption)
                        if let m = def.model { Circle().fill(Theme.model(m).fill).frame(width: 10, height: 10) }
                        Text(name).font(.headline)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
                Spacer()
                if let doing = activity(state, model: model, name: def.model?.info.name ?? "the model") {
                    Text(doing).font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Find", action: onFind).buttonStyle(.link).font(.caption)
                }
            }
            if isOpen {
                if state.status == .skipped {
                    Text("Not taken on this run.").font(.callout).foregroundStyle(.secondary)
                } else if let v = shown {
                    if node.type == "view" || node.type == "gallery" || node.type == "table" {
                        StepBody(node: node)
                    } else {
                        ResultView(value: v)
                    }
                } else {
                    Text("Waiting for a result.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.background.secondary))
    }

    private var shown: Value? {
        if def.category == .output { return state.inputs.values.first }
        guard let out = def.visibleOutputs(node.params).first, let v = state.outputs?[out.id] else { return nil }
        if out.id == "language", let s = v.string { return .text(languageName(s)) }
        return v
    }
}
