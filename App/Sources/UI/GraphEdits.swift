import Foundation

/// The edits the editor makes to a flow's steps and wires, apart from the
/// views so they can be tested. Callers make them on a copy and write it back
/// once, so each edit is one step to undo.
extension Graph {
    enum MoveRefusal: Error {
        /// The step can't take what the step before the gap gives.
        case doesNotFit
        /// The flow would loop back on itself.
        case loops
    }

    /// Adds a step that takes from `anchor` and the steps before it, nearest
    /// first, and from `output` of the anchor before any other.
    @MainActor @discardableResult
    mutating func addStep(_ type: String, id: String, at position: CGPoint, after anchor: Node?,
                          output: String? = nil, session: FlowSession? = nil) -> Bool {
        guard let def = Steps.byType[type] else { return false }
        nodes.append(Node(id: id, type: type, position: position, params: def.defaults))
        if let anchor {
            let given = upstreamOutputs(from: anchor, in: self, session: session)
            let first = output.map { o in given.filter { $0.node.id == anchor.id && $0.port.id == o } } ?? []
            wireIn(id, def, from: first + given)
        }
        if type == "if" { checkWhatItWasGiven(id) }
        return true
    }

    /// Adds a step between two others: it takes what `source` gave `before`,
    /// and `before` takes from it instead, where their kinds fit.
    @MainActor @discardableResult
    mutating func insert(_ type: String, id: String, at position: CGPoint, after source: String, _ handle: String,
                         before: String?, session: FlowSession? = nil) -> Bool {
        guard let src = node(source), addStep(type, id: id, at: position, after: src, output: handle, session: session) else { return false }
        guard let before else { return true }
        place(id, before: before)
        // Only a step that takes what `before` took goes in its way; one fed
        // from further up, like Voz after Ear, sits beside it.
        if incoming(id).contains(where: { $0.source == source && $0.sourceHandle == handle }) {
            feed(before, from: id, inPlaceOf: (source, handle), session: session)
        }
        return true
    }

    /// Takes a step out of where it is, joining the step before it to the
    /// steps after it, and puts it between `after` and `before`. A Split takes
    /// its If and Else sides with it and checks what it is now given, as a
    /// new one would. The graph is left as it was when the move is refused.
    @MainActor
    mutating func move(_ id: String, after: (node: String, output: String), before: String?,
                       session: FlowSession? = nil) -> MoveRefusal? {
        guard id != after.node, id != before, let moving = node(id), moving.type != "merge", let def = moving.def
        else { return .doesNotFit }
        var g = self
        let isIf = moving.type == "if"
        if isIf {
            g.edges.removeAll { $0.target == id }
        } else {
            let incoming = g.incoming(id)
            let main = incoming.first { $0.targetHandle == def.inputs.first?.id } ?? incoming.first
            let outgoing = g.edges.filter { $0.source == id }
            g.edges.removeAll { $0.source == id || $0.target == id }
            if let main {
                for e in outgoing {
                    let bridge = Edge(source: main.source, sourceHandle: main.sourceHandle, target: e.target, targetHandle: e.targetHandle)
                    if g.canConnect(bridge) { g.connect(bridge) }
                }
            }
        }
        guard let from = g.node(after.node), let port = from.def?.outputs.first(where: { $0.id == after.output }) else { return .doesNotFit }
        let kind = outputKind(from, port, session: session)
        guard let input = def.inputs.first(where: { port.type.fits($0.type) && accepts($0, of: def, kind) }) else { return .doesNotFit }
        let into = Edge(source: after.node, sourceHandle: after.output, target: id, targetHandle: input.id)
        guard g.canConnect(into) else { return .loops }
        g.connect(into)
        if isIf { g.checkWhatItWasGiven(id) }
        if let before {
            g.place(id, before: before)
            if !isIf { g.feed(before, from: id, inPlaceOf: after, session: session) }
        }
        self = g
        return nil
    }

    /// Else if: an If under another's Else that sorts what reached Else, on
    /// the same check, so only the value is left to set. In a flow laid out
    /// by hand it goes `at` a free spot; otherwise just after its parent, for
    /// the order.
    @discardableResult
    mutating func addElseIf(under parentID: String, id: String, at spot: CGPoint? = nil) -> Bool {
        guard let parent = node(parentID), parent.type == "if", let def = Steps.byType["if"] else { return false }
        var params = def.defaults
        params["op"] = parent.params["op"]
        nodes.append(Node(id: id, type: "if", position: spot ?? CGPoint(x: parent.position.x + 1, y: parent.position.y + 1), params: params))
        connect(Edge(source: parentID, sourceHandle: "no", target: id, targetHandle: "value"))
        checkWhatItWasGiven(id)
        return true
    }

    /// A copy of a step right after it, taking the same inputs, and `at` a
    /// free spot in a flow laid out by hand.
    @discardableResult
    mutating func duplicate(_ id: String, as copy: String, at spot: CGPoint? = nil) -> Bool {
        guard let original = node(id) else { return false }
        nodes.append(Node(id: copy, type: original.type, position: spot ?? CGPoint(x: original.position.x + 1, y: original.position.y),
                          params: original.params))
        for e in incoming(id) { connect(Edge(source: e.source, sourceHandle: e.sourceHandle, target: copy, targetHandle: e.targetHandle)) }
        return true
    }

    /// Feeds one input from `key`, a "step::output" pair, or empties it when
    /// `key` is nil.
    mutating func wire(_ target: String, _ handle: String, from key: String?) {
        edges.removeAll { $0.target == target && $0.targetHandle == handle }
        let parts = key?.components(separatedBy: "::") ?? []
        if parts.count == 2 {
            let edge = Edge(source: parts[0], sourceHandle: parts[1], target: target, targetHandle: handle)
            if canConnect(edge) { connect(edge) }
        }
        if node(target)?.type == "if", handle == "test" { sendOnWhatWasChecked(target) }
    }

    /// A new If checks what it was wired to, and sends on what that was about.
    mutating func checkWhatItWasGiven(_ ifID: String) {
        guard let given = incoming(ifID).first(where: { $0.targetHandle == "value" }) else { return }
        // Under another If's side, it sorts that side, on the same check.
        if node(given.source)?.type == "if" {
            if let test = incoming(given.source).first(where: { $0.targetHandle == "test" }) {
                connect(Edge(source: test.source, sourceHandle: test.sourceHandle, target: ifID, targetHandle: "test"))
            }
            return
        }
        connect(Edge(source: given.source, sourceHandle: given.sourceHandle, target: ifID, targetHandle: "test"))
        sendOnWhatWasChecked(ifID)
    }

    /// An If sends on what its check was about: for Eye's verdict on a photo,
    /// the photo Eye looked at, not the verdict. A check on a step with
    /// nothing before it sends that step's own value.
    mutating func sendOnWhatWasChecked(_ ifID: String) {
        if let given = incoming(ifID).first(where: { $0.targetHandle == "value" }),
           node(given.source)?.type == "if" { return }
        guard let test = incoming(ifID).first(where: { $0.targetHandle == "test" }),
              let checked = node(test.source)
        else { return }
        let fed = checked.def?.inputs.first.flatMap { input in incoming(checked.id).first { $0.targetHandle == input.id } }
        let value = Edge(source: fed?.source ?? test.source, sourceHandle: fed?.sourceHandle ?? test.sourceHandle,
                         target: ifID, targetHandle: "value")
        if canConnect(value) { connect(value) }
    }

    /// Puts a step that now feeds `before` just ahead of it, so the step list,
    /// which breaks ties by place on the canvas, shows it in the gap it went
    /// into rather than after every other branch. A flow laid out by hand
    /// keeps its places.
    @discardableResult
    mutating func place(_ id: String, before: String) -> Bool {
        guard !meta.arranged, let b = node(before), let i = index(of: id) else { return false }
        nodes[i].position = CGPoint(x: b.position.x - 1, y: b.position.y)
        return true
    }

    /// Has `before` take from `id` what it took from `old`, where the kinds fit.
    @MainActor
    private mutating func feed(_ before: String, from id: String, inPlaceOf old: (node: String, output: String), session: FlowSession?) {
        guard let new = node(id), let def = new.def, let needs = node(before)?.def else { return }
        for edge in edges where edge.source == old.node && edge.sourceHandle == old.output && edge.target == before {
            guard let input = needs.inputs.first(where: { $0.id == edge.targetHandle }),
                  let output = def.outputs.first(where: { $0.type.fits(input.type) && accepts(input, of: needs, outputKind(new, $0, session: session)) })
            else { continue }
            let replacement = Edge(source: id, sourceHandle: output.id, target: before, targetHandle: edge.targetHandle)
            if canConnect(replacement) { connect(replacement) }
        }
    }

    /// Feeds a new step's inputs from the nearest outputs that fit: each
    /// input it needs, or its first when every one is optional.
    private mutating func wireIn(_ id: String, _ def: StepDef, from sources: [(node: Node, port: Port, kind: Kind)]) {
        let needed = def.inputs.filter { !$0.optional }
        for input in needed.isEmpty ? Array(def.inputs.prefix(1)) : needed {
            guard let s = nearest(for: input, of: def, in: sources) else { continue }
            connect(Edge(source: s.node.id, sourceHandle: s.port.id, target: id, targetHandle: input.id))
        }
    }
}
