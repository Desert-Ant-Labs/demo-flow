import Foundation
import Testing
@testable import Flow

/// How wires find their way on the canvas.
@Suite struct WireRouteTests {
    private let card = CGRect(x: 400, y: -150, width: 300, height: 300)

    @Test func aWireToTheNextColumnTurnsInTheGutter() {
        let corners = WireRoute.corners(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 380, y: 40), around: [card])
        #expect(corners.count == 4)
        #expect(corners[1].x == corners[2].x && corners[1].y == 0 && corners[2].y == 40)
    }

    @Test func aLevelWireIsStraight() {
        #expect(WireRoute.corners(from: CGPoint(x: 0, y: 10), to: CGPoint(x: 300, y: 10)).count == 2)
    }

    @Test func aWireThatSkipsAColumnGoesOverTheCardBetween() {
        let corners = WireRoute.corners(from: CGPoint(x: 300, y: -40), to: CGPoint(x: 800, y: 0), around: [card])
        let lane = corners.map(\.y).min()!
        #expect(lane <= card.minY - WireRoute.clearance)
        #expect(corners[1].x < card.minX && corners[4].x > card.maxX)
    }

    @Test func itGoesUnderWhenThatIsShorter() {
        let corners = WireRoute.corners(from: CGPoint(x: 300, y: 120), to: CGPoint(x: 800, y: 130), around: [card])
        #expect(corners.map(\.y).max()! >= card.maxY + WireRoute.clearance)
    }

    @Test func itClearsACardStackedAboveTheOneInTheWay() {
        let above = CGRect(x: 420, y: -500, width: 280, height: 320)
        let corners = WireRoute.corners(from: CGPoint(x: 300, y: -60), to: CGPoint(x: 800, y: -60), around: [card, above])
        let lane = corners.count == 6 ? corners[2].y : 0
        #expect(lane <= above.minY - WireRoute.clearance || lane >= card.maxY + WireRoute.clearance)
    }

    @Test func aWireBackwardsRunsUnderBothCards() {
        let source = CGRect(x: 600, y: -100, width: 200, height: 200), target = CGRect(x: 100, y: -50, width: 200, height: 300)
        let corners = WireRoute.corners(from: CGPoint(x: 800, y: 0), to: CGPoint(x: 100, y: 0), source: source, target: target)
        #expect(corners.map(\.y).max()! >= target.maxY + WireRoute.clearance)
    }

    @Test func wiresFromOneOutputFanOut() {
        let a = WireRoute.corners(from: .zero, to: CGPoint(x: 300, y: -80), spread: -3.5)
        let b = WireRoute.corners(from: .zero, to: CGPoint(x: 300, y: 80), spread: 3.5)
        #expect(a[1].x != b[1].x)
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
