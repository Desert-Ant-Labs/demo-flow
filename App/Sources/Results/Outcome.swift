import Foundation

/// One thing a flow produced, in the shape the Results page, the results
/// panel, and the exports all show it: the steps that end the flow, and any
/// step whose result nothing else takes.
struct Outcome: Identifiable {
    /// What a result holds, already sorted into the forms it is shown in.
    enum Content {
        /// Any value, shown as `mode` says or as fits it best.
        case value(Value, mode: ValueKind)
        /// Photos, each with the words a step gave it.
        case photos([Captioned])
        /// Rows under named columns: a Table step, or a list of records.
        case table(columns: [String], rows: [[Value?]])
    }

    struct Captioned: Identifiable {
        let id: Int
        let photo: Photo
        let caption: String?
    }

    /// The step's id.
    let id: String
    /// What the step is called in the flow, the same as on its card.
    let name: String
    let model: ModelID?
    let state: StepState
    let content: Content?

    /// The result as a single value, for copying, saving, and sharing.
    var value: Value? {
        switch content {
        case .value(let v, _): v
        case .photos(let items): .list(items.map { .image($0.photo) })
        case .table(let columns, let rows): .list(rows.map { row in .record(zip(columns, row).compactMap { k, v in v.map { (k, $0) } }) })
        case nil: nil
        }
    }

    /// Whether there is anything to show yet.
    var isEmpty: Bool {
        switch content {
        case nil: true
        case .value(let v, _): v.isList && v.present.isEmpty
        case .photos(let items): items.isEmpty
        case .table(_, let rows): rows.isEmpty
        }
    }
}

extension Outcome {
    /// What `graph` produced in `engine`'s last run, the steps that end the flow first.
    @MainActor
    static func all(in graph: Graph, engine: Engine) -> [Outcome] {
        let feeds = Set(graph.edges.map(\.source))
        let names = graph.names()
        return graph.ordered
            .filter { node in
                guard let def = node.def, node.type != "note", def.category != .input else { return false }
                return def.category == .output || !feeds.contains(node.id)
            }
            .sorted { ($0.def?.category == .output ? 0 : 1) < ($1.def?.category == .output ? 0 : 1) }
            .compactMap { node in
                guard let def = node.def else { return nil }
                let state = engine.state(node.id)
                return Outcome(id: node.id, name: names[node.id] ?? def.title, model: def.model, state: state,
                               content: content(of: node, def, state))
            }
    }

    private static func content(of node: Node, _ def: StepDef, _ state: StepState) -> Content? {
        switch node.type {
        case "gallery":
            guard let photos = state.inputs["photos"] else { return nil }
            let captions = state.inputs["captions"]?.items.map { $0.map(caption) }
            return .photos(photos.items.enumerated().compactMap { i, v in
                v?.photo.map { Captioned(id: i, photo: $0, caption: captions.flatMap { i < $0.count ? $0[i] : nil }) }
            })
        case "table":
            return table(node, state)
        default:
            let value: Value?
            if def.category == .output {
                value = state.inputs["value"] ?? state.inputs.values.first
            } else if let out = def.visibleOutputs(node.params).first, let v = state.outputs?[out.id] {
                value = out.id == "language" ? v.string.map { .text(languageName($0)) } ?? v : v
            } else {
                value = nil
            }
            guard let value else { return nil }
            let mode = ValueKind(rawValue: node.params["as"]?.string ?? "") ?? .auto
            let items = value.present
            // Records read best as a table, unless they are only labels with
            // scores, which read as a chart. Records that carry text, as
            // Redact's finds do, stay a table.
            let chart = scored(items) != nil && items.first?["text"] == nil
            if mode == .table || (mode == .auto && !chart), value.isList || value.isStream, !items.isEmpty, items.allSatisfy(\.isRecord) {
                var columns: [String] = []
                for case .record(let fields) in items { for (k, _) in fields where !columns.contains(k) { columns.append(k) } }
                return .table(columns: columns, rows: items.map { item in columns.map { item[$0] } })
            }
            if mode == .auto || mode == .gallery, !items.isEmpty, items.allSatisfy({ $0.photo != nil }), value.isList || value.isStream {
                return .photos(items.enumerated().map { Captioned(id: $0, photo: $1.photo!, caption: nil) })
            }
            return .value(value, mode: mode)
        }
    }

    /// The Table step's columns, named as its setting says, lined up item by item.
    private static func table(_ node: Node, _ state: StepState) -> Content? {
        let keys = ["a", "b", "c"].filter { state.inputs[$0] != nil }
        guard !keys.isEmpty else { return nil }
        let names = (node.params["columns"]?.string ?? "").split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let columns = keys.enumerated().map { i, k in i < names.count && !names[i].isEmpty ? names[i] : k }
        let cell = { (k: String, i: Int) -> Value? in
            guard let v = state.inputs[k] else { return nil }
            return v.isStream ? (i < v.items.count ? v.items[i] : nil) : v
        }
        let count = keys.compactMap { state.inputs[$0] }.map { $0.isStream ? $0.items.count : 1 }.max() ?? 0
        let rows = (0..<count).filter { cell(keys[0], $0) != nil }.map { i in keys.map { cell($0, i) } }
        return .table(columns: columns, rows: rows)
    }

    /// The words under a photo: a label, or a few labels joined.
    private static func caption(_ value: Value) -> String {
        if case .list(let items) = value { return items.compactMap { $0?.asText }.joined(separator: ", ") }
        return value.asText
    }
}
