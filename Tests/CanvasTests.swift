import Foundation
import Testing
@testable import Flow

/// How wires find their way on the canvas.
@Suite struct WireRouteTests {
    private let card = CGRect(x: 400, y: -150, width: 300, height: 300)

    @Test func aWireToTheNextColumnTakesThePlainCurve() {
        #expect(WireRoute.lane(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 380, y: 40), around: [card]) == nil)
    }

    @Test func aWireThatSkipsAColumnGoesAroundTheCardBetween() throws {
        let a = CGPoint(x: 300, y: -40), b = CGPoint(x: 800, y: 0)
        let lane = try #require(WireRoute.lane(from: a, to: b, around: [card]))
        #expect(lane.y <= card.minY - WireRoute.clearance)
        #expect(lane.from <= card.minX && lane.to >= card.maxX)
    }

    @Test func itGoesUnderWhenThatIsShorter() throws {
        let a = CGPoint(x: 300, y: 120), b = CGPoint(x: 800, y: 130)
        let lane = try #require(WireRoute.lane(from: a, to: b, around: [card]))
        #expect(lane.y >= card.maxY + WireRoute.clearance)
    }

    @Test func itClearsACardStackedAboveTheOneInTheWay() throws {
        let above = CGRect(x: 420, y: -500, width: 280, height: 320)
        let lane = try #require(WireRoute.lane(from: CGPoint(x: 300, y: -60), to: CGPoint(x: 800, y: -60), around: [card, above]))
        #expect(lane.y <= above.minY - WireRoute.clearance || lane.y >= card.maxY + WireRoute.clearance)
    }

    @Test func aWireBackwardsIsLeftAlone() {
        #expect(WireRoute.lane(from: CGPoint(x: 800, y: 0), to: CGPoint(x: 300, y: 0), around: [card]) == nil)
    }
}

/// What steps are called.
@MainActor
@Suite struct StepNameTests {
    private func node(_ id: String, _ type: String, label: String? = nil) -> Node {
        var params = Steps.byType[type]?.defaults ?? [:]
        if let label { params["label"] = .string(label) }
        return Node(id: id, type: type, position: .zero, params: params)
    }

    @Test func aStepGoesByItsKindOrModel() {
        var g = Graph()
        g.nodes = [node("in", "photos"), node("eye", "eye")]
        #expect(g.name(of: "in") == "Photos")
        #expect(g.name(of: "eye") == "Eye")
    }

    @Test func twoOfAKindGoByTheirHandWrittenIds() {
        var g = Graph()
        g.nodes = [node("groups", "gallery"), node("portraits", "gallery")]
        #expect(g.name(of: "groups") == "Groups")
        #expect(g.name(of: "portraits") == "Portraits")
    }

    @Test func twoOfAKindTheEditorMadeAreNumbered() {
        var g = Graph()
        g.nodes = [node("gallery-mf3k2a1", "gallery"), node("gallery-mf3k2b2", "gallery")]
        #expect(g.name(of: "gallery-mf3k2a1") == "Gallery")
        #expect(g.name(of: "gallery-mf3k2b2") == "Gallery 2")
    }

    @Test func aGivenNameWins() {
        var g = Graph()
        g.nodes = [node("groups", "gallery", label: "Friends"), node("portraits", "gallery")]
        #expect(g.name(of: "groups") == "Friends")
        #expect(g.defaultName(of: "groups") == "Groups")
    }

    @Test func idsReadAsWords() {
        #expect(Graph.readable("best_shot", type: "best") == "Best shot")
        #expect(Graph.readable("closedEyes", type: "if") == "Closed eyes")
        #expect(Graph.readable("if-mf3k2a1", type: "if") == nil)
    }
}
