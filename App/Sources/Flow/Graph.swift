import Foundation

/// One step on the canvas.
struct Node: Identifiable, Hashable, Sendable {
    var id: String
    var type: String
    var position: CGPoint
    var params: Params

    var def: StepDef? { Steps.byType[type] }
}

/// A wire from one step's output to another step's input.
struct Edge: Identifiable, Hashable, Sendable {
    var source: String
    var sourceHandle: String
    var target: String
    var targetHandle: String

    var id: String { "\(source).\(sourceHandle)-\(target).\(targetHandle)" }
}

struct FlowMeta: Hashable, Sendable {
    var title = ""
    var description = ""
    /// Set once someone moves a step by hand. Until then the flow lays itself
    /// out again as its cards grow.
    var arranged = false
}

/// A whole flow: what a document holds.
struct Graph: Hashable, Sendable {
    var meta = FlowMeta()
    var nodes: [Node] = []
    var edges: [Edge] = []

    func node(_ id: String) -> Node? { nodes.first { $0.id == id } }

    func index(of id: String) -> Int? { nodes.firstIndex { $0.id == id } }

    /// Which of a step's outputs have a wire on them.
    func wiredFrom(_ id: String) -> Set<String> {
        Set(edges.filter { $0.source == id }.map(\.sourceHandle))
    }

    func incoming(_ id: String) -> [Edge] {
        edges.filter { $0.target == id }
    }

    /// The models this flow runs, in the order its steps use them.
    var models: [ModelID] {
        var seen: [ModelID] = []
        for n in nodes {
            for m in n.def?.models(n.params) ?? [] where !seen.contains(m) { seen.append(m) }
        }
        return seen
    }

    /// Whether a start step runs on the app's samples rather than on files of
    /// yours, as a template does until you add your own or a trigger fills it.
    var runsOnSamples: Bool {
        nodes.contains { n in
            guard n.params["files"]?.strings.isEmpty ?? true, n.params["file"]?.string?.isEmpty ?? true else { return false }
            return !(n.params["samples"]?.strings.isEmpty ?? true) || !(n.params["sample"]?.string?.isEmpty ?? true)
        }
    }

    /// Steps in an order where each comes after what it uses. Ties go left to
    /// right, top to bottom, as on the canvas.
    var ordered: [Node] {
        var placed = Set<String>()
        var out: [Node] = []
        let ids = Set(nodes.map(\.id))
        var pending = nodes.sorted { ($0.position.x, $0.position.y) < ($1.position.x, $1.position.y) }
        while !pending.isEmpty {
            // Reading a file drops a wire that would close a loop and the editor
            // never makes one; should one get through, it falls back to canvas order.
            let i = pending.firstIndex { n in
                edges.allSatisfy { $0.target != n.id || placed.contains($0.source) || !ids.contains($0.source) }
            } ?? 0
            let next = pending.remove(at: i)
            placed.insert(next.id)
            out.append(next)
        }
        return out
    }

    /// Whether some wires lead in a circle. Reading a file or link drops the
    /// wire that would close one and the editor never makes one, so this
    /// guards against a bug: such a flow would wait on itself forever.
    var hasCycle: Bool {
        var waiting = Dictionary(nodes.map { ($0.id, 0) }, uniquingKeysWith: { a, _ in a })
        let live = edges.filter { waiting[$0.source] != nil && waiting[$0.target] != nil }
        for e in live { waiting[e.target]! += 1 }
        var ready = waiting.filter { $0.value == 0 }.map(\.key)
        var done = 0
        while let id = ready.popLast() {
            done += 1
            for e in live where e.source == id {
                waiting[e.target]! -= 1
                if waiting[e.target] == 0 { ready.append(e.target) }
            }
        }
        return done < waiting.count
    }

    /// Whether wires lead from step `start` to step `end`.
    func reaches(_ end: String, from start: String) -> Bool {
        var seen = Set<String>()
        func walk(_ id: String) -> Bool {
            if id == end { return true }
            guard seen.insert(id).inserted else { return false }
            return edges.contains { $0.source == id && walk($0.target) }
        }
        return walk(start)
    }

    /// Connects two ports, replacing whatever fed that input before.
    mutating func connect(_ edge: Edge) {
        edges.removeAll { $0.target == edge.target && $0.targetHandle == edge.targetHandle }
        edges.append(edge)
    }

    mutating func remove(_ ids: Set<String>) {
        nodes.removeAll { ids.contains($0.id) }
        edges.removeAll { ids.contains($0.source) || ids.contains($0.target) }
    }

    /// Whether an output can feed an input without closing a loop.
    func canConnect(_ edge: Edge) -> Bool {
        guard edge.source != edge.target,
              let from = node(edge.source)?.def?.outputs.first(where: { $0.id == edge.sourceHandle }),
              let to = node(edge.target)?.def?.inputs.first(where: { $0.id == edge.targetHandle }),
              from.type.fits(to.type)
        else { return false }
        return !reaches(edge.source, from: edge.target)
    }
}

@MainActor private var counter = 0

/// A new step's id: its type and something unique, as the web app makes them.
@MainActor func newNodeID(_ type: String) -> String {
    counter += 1
    let stamp = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
    return "\(type)-\(stamp)\(String(counter, radix: 36))"
}
