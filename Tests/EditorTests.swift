import Foundation
import AppIntents
import CoreText
import Testing
@testable import Flow

/// The editor's edits to steps and wires, on small flows built here.
@MainActor
@Suite struct GraphEditTests {
    private func node(_ id: String, _ type: String, x: CGFloat) -> Node {
        Node(id: id, type: type, position: CGPoint(x: x, y: 0), params: Steps.byType[type]?.defaults ?? [:])
    }

    private func edge(_ from: String, _ output: String, _ to: String, _ input: String) -> Edge {
        Edge(source: from, sourceHandle: output, target: to, targetHandle: input)
    }

    private func has(_ g: Graph, _ e: Edge) -> Bool { g.edges.contains(e) }

    /// Photos, Eye on each, a Split on Eye's reason that sorts the photos, and
    /// a Result on the If side.
    private var sorted: Graph {
        var g = Graph()
        g.nodes = [node("in", "photos", x: 0), node("eye", "eye", x: 100), node("if", "if", x: 200), node("show", "view", x: 300)]
        g.edges = [edge("in", "photos", "eye", "image"), edge("in", "photos", "if", "value"),
                   edge("eye", "reason", "if", "test"), edge("if", "yes", "show", "value")]
        return g
    }

    @Test func movingASplitTakesItsSidesAndChecksWhatItIsGiven() {
        var g = sorted
        let r1 = g.move("if", after: ("eye", "type"), before: nil)
        #expect(r1 == nil)
        #expect(has(g, edge("eye", "type", "if", "test")))
        #expect(has(g, edge("in", "photos", "if", "value")))
        #expect(has(g, edge("if", "yes", "show", "value")))
        #expect(!g.edges.contains { $0.target == "show" && $0.source != "if" })
    }

    @Test func movingAStepJoinsItsNeighbors() {
        var g = Graph()
        g.nodes = [node("t", "text", x: 0), node("lang", "tongue", x: 100), node("show", "view", x: 200), node("tpl", "template", x: 300)]
        g.edges = [edge("t", "text", "lang", "text"), edge("lang", "language", "show", "value"), edge("t", "text", "tpl", "a")]
        let r2 = g.move("lang", after: ("tpl", "text"), before: nil)
        #expect(r2 == nil)
        #expect(has(g, edge("t", "text", "show", "value")))
        #expect(has(g, edge("tpl", "text", "lang", "text")))
    }

    @Test func aMoveThatLoopsIsRefusedAndChangesNothing() {
        var g = sorted
        let before = g
        let r3 = g.move("eye", after: ("show", "value"), before: nil)
        #expect(r3 != nil)
        #expect(g == before)
    }

    @Test func aMergeStaysPut() {
        var g = sorted
        g.nodes.append(node("merge", "merge", x: 400))
        let before = g
        let r4 = g.move("merge", after: ("in", "photos"), before: nil)
        #expect(r4 == .doesNotFit)
        #expect(g == before)
    }

    /// Tongue's language is a short label, which Gist can't read, so Gist
    /// keeps the text it had.
    @Test func insertingKeepsWiresWhoseKindsDoNotFit() {
        var g = Graph()
        g.nodes = [node("t", "text", x: 0), node("gist", "gist", x: 200)]
        g.edges = [edge("t", "text", "gist", "text")]
        let r5 = g.insert("tongue", id: "lang", at: .zero, after: "t", "text", before: "gist")
        #expect(r5)
        #expect(has(g, edge("t", "text", "lang", "text")))
        #expect(has(g, edge("t", "text", "gist", "text")))
    }

    @Test func insertingPutsTheStepInTheGap() {
        var g = Graph()
        g.nodes = [node("t", "text", x: 0), node("show", "view", x: 200)]
        g.edges = [edge("t", "text", "show", "value")]
        let r6 = g.insert("tongue", id: "lang", at: CGPoint(x: 500, y: 0), after: "t", "text", before: "show")
        #expect(r6)
        #expect(has(g, edge("t", "text", "lang", "text")))
        #expect(g.incoming("show").first?.source == "lang")
        #expect(g.ordered.map(\.id) == ["t", "lang", "show"])
    }

    @Test func elseIfSortsWhatReachedElseOnTheSameCheck() {
        var g = sorted
        g.nodes[2].params["op"] = "oneOf"
        let r7 = g.addElseIf(under: "if", id: "if2")
        #expect(r7)
        #expect(has(g, edge("if", "no", "if2", "value")))
        #expect(has(g, edge("eye", "reason", "if2", "test")))
        #expect(g.node("if2")?.params["op"] == "oneOf")
    }

    @Test func aNewSplitSendsOnWhatItsCheckWasAbout() {
        var g = Graph()
        g.nodes = [node("in", "photos", x: 0), node("eye", "eye", x: 100)]
        g.edges = [edge("in", "photos", "eye", "image")]
        g.nodes[1].params["fields"] = ["reason"]
        let r8 = g.insert("if", id: "if", at: .zero, after: "eye", "reason", before: nil)
        #expect(r8)
        #expect(has(g, edge("eye", "reason", "if", "test")))
        #expect(has(g, edge("in", "photos", "if", "value")))
    }

    @Test func aCopyGoesWhereItIsTold() {
        var g = sorted
        g.duplicate("show", as: "copy", at: CGPoint(x: 300, y: 400))
        g.addElseIf(under: "if", id: "elif", at: CGPoint(x: 300, y: 800))
        #expect(g.node("copy")?.position == CGPoint(x: 300, y: 400))
        #expect(g.node("elif")?.position == CGPoint(x: 300, y: 800))
    }

    @Test func duplicateTakesTheSameInputs() {
        var g = sorted
        let r9 = g.duplicate("show", as: "copy")
        #expect(r9)
        #expect(has(g, edge("if", "yes", "copy", "value")))
        #expect(g.node("copy")?.type == "view")
    }

    @Test func wiringASplitsCheckSendsOnWhatItWasAbout() {
        var g = sorted
        g.wire("if", "test", from: nil)
        #expect(!g.edges.contains { $0.target == "if" && $0.targetHandle == "test" })
        g.wire("if", "test", from: "eye::type")
        #expect(has(g, edge("eye", "type", "if", "test")))
        #expect(has(g, edge("in", "photos", "if", "value")))
    }
}
