import Foundation
import Yams

/// A flow as YAML, the same format the web app reads and writes: each step
/// names what it uses ("step.output") and its settings. A flow laid out by
/// hand also keeps each step's place on the canvas (`at`), which the web app
/// ignores and lays out again.
enum FlowFile {
    static let header = "# Desert Ant Flow. Open it in Desert Ant Flow for Mac or at https://flow.desertant.com.\n"

    struct NotAFlow: LocalizedError {
        var errorDescription: String? { "That is not a Desert Ant flow" }
    }

    struct SameID: LocalizedError {
        let id: String
        var errorDescription: String? { "Two steps in this flow have the same id, \"\(id)\"" }
    }

    struct TooBig: LocalizedError {
        var errorDescription: String? { "That flow is too big to open" }
    }

    /// A flow with hours of transcribed words stays well under these. YAML
    /// can repeat a part by name (`*name`), so a few lines can stand for
    /// billions of values; the count stops reading long before that.
    static let maxBytes = 8 << 20
    static let maxValues = 1_000_000

    static func looksLikeFlow(_ text: String) -> Bool {
        text.contains(#/(?m)^\s*flow:\s*1\b/#) && text.contains("steps:")
    }

    static func read(_ text: String) throws -> Graph {
        guard text.utf8.count <= maxBytes else { throw TooBig() }
        guard let tree = try Yams.compose(yaml: text) else { throw NotAFlow() }
        guard count(tree, upTo: maxValues) <= maxValues else { throw TooBig() }
        guard let doc = tree.any as? [String: Any],
              (doc["flow"] as? Int) == 1, let steps = doc["steps"] as? [[String: Any]]
        else { throw NotAFlow() }
        var graph = Graph()
        graph.meta.title = doc["title"] as? String ?? ""
        graph.meta.description = doc["description"] as? String ?? ""
        let known = steps.compactMap { s -> (id: String, def: StepDef, fields: [String: Any])? in
            guard let id = s["id"], let type = s["type"] as? String, let def = Steps.byType[type] else { return nil }
            return ("\(id)", def, s)
        }
        var ids = Set<String>()
        for step in known where !ids.insert(step.id).inserted { throw SameID(id: step.id) }
        var placed = false
        for (i, (id, def, s)) in known.enumerated() {
            var params = def.defaults
            for (k, v) in (s["with"] as? [String: Any]) ?? [:] { params[k] = JSON(any: v) }
            var position = CGPoint(x: Double(i) * 330, y: 0)
            if let at = s["at"] as? [Any], at.count == 2,
               let x = (at[0] as? NSNumber)?.doubleValue, let y = (at[1] as? NSNumber)?.doubleValue {
                position = CGPoint(x: x, y: y)
                placed = true
            }
            graph.nodes.append(Node(id: id, type: def.type, position: position, params: params))
            for (handle, from) in (s["uses"] as? [String: Any]) ?? [:] {
                let parts = "\(from)".split(separator: ".", maxSplits: 1).map(String.init)
                guard parts.count == 2, ids.contains(parts[0]) else { continue }
                graph.edges.append(Edge(source: parts[0], sourceHandle: parts[1], target: id, targetHandle: handle))
            }
        }
        // A wire that closes a loop is dropped, so the flow can still run.
        var kept: [Edge] = []
        for edge in graph.edges {
            var trial = graph
            trial.edges = kept
            if edge.source != edge.target && !trial.reaches(edge.source, from: edge.target) { kept.append(edge) }
        }
        graph.edges = kept
        graph.meta.arranged = placed
        return graph
    }

    /// How many values a YAML tree holds, each use of a repeated part
    /// counted again, as reading it would make them. Stops once past `limit`.
    private static func count(_ tree: YNode, upTo limit: Int) -> Int {
        var count = 0
        var stack = [tree]
        while count <= limit, let node = stack.popLast() {
            count += 1
            switch node {
            case .mapping(let m): for pair in m { stack += [pair.key, pair.value] }
            case .sequence(let s): stack += Array(s)
            default: break
            }
        }
        return count
    }

    /// The flow as YAML. `link` leaves out the header and the positions, for a
    /// share link that should be as short as it can be.
    static func write(_ graph: Graph, link: Bool = false) -> String {
        let notes = graph.nodes.filter { $0.type == "note" }
        let steps = graph.ordered.filter { $0.type != "note" } + notes
        var root: [(YNode, YNode)] = [(key("flow"), YNode("1", Tag(.int)))]
        if !graph.meta.title.isEmpty { root.append((key("title"), string(graph.meta.title))) }
        if !graph.meta.description.isEmpty { root.append((key("description"), string(graph.meta.description))) }
        root.append((key("steps"), .sequence(.init(steps.map { step(graph, $0, link: link) }))))
        let yaml = (try? Yams.serialize(node: .mapping(.init(root)), width: 100, allowUnicode: true)) ?? ""
        return link ? yaml : header + yaml
    }

    private static func step(_ graph: Graph, _ n: Node, link: Bool) -> YNode {
        var pairs: [(YNode, YNode)] = [(key("id"), string(n.id)), (key("type"), string(n.type))]
        let uses = graph.incoming(n.id).sorted { $0.targetHandle < $1.targetHandle }
        if !uses.isEmpty {
            pairs.append((key("uses"), .mapping(.init(uses.map { (key($0.targetHandle), string("\($0.source).\($0.sourceHandle)")) }))))
        }
        let settings = n.params.filter { !$0.key.hasPrefix("_") && $0.value != .null }
        if !settings.isEmpty {
            pairs.append((key("with"), .mapping(.init(settings.keys.sorted().map { (key($0), node(settings[$0]!)) }))))
        }
        if graph.meta.arranged && !link {
            pairs.append((key("at"), .sequence(.init([number(n.position.x.rounded()), number(n.position.y.rounded())], Tag(.seq), .flow))))
        }
        return .mapping(.init(pairs))
    }

    private static func key(_ s: String) -> YNode { YNode(s) }

    /// Text that YAML would read back as something else, a number or a flag, is
    /// quoted.
    private static func string(_ s: String) -> YNode {
        if s.contains("\n") { return YNode(s, Tag(.str), .literal) }
        return YNode(s, Tag(.str), YNode(s).tag == Tag(.str) ? .any : .doubleQuoted)
    }

    private static func number(_ d: Double) -> YNode {
        YNode(d.wholeValue.map { String($0) } ?? String(d), Tag(.float))
    }

    private static func node(_ json: JSON) -> YNode {
        switch json {
        case .null: YNode("null", Tag(.null))
        case .bool(let b): YNode(b ? "true" : "false", Tag(.bool))
        case .number(let n): number(n)
        case .string(let s): string(s)
        case .array(let a): .sequence(.init(a.map(node)))
        case .object(let o): .mapping(.init(o.keys.sorted().map { (key($0), node(o[$0]!)) }))
        }
    }
}

/// Yams calls its node type `Node`, as this app calls a step.
typealias YNode = Yams.Node
