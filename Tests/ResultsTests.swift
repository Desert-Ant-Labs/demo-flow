import Foundation
import Testing
@testable import Flow

@MainActor
@Suite struct ResultsTests {
    /// Three texts into a Table step's first column and a Result step.
    private func graph() -> Graph {
        var g = Graph()
        g.nodes = [Node(id: "in", type: "textlist", position: .zero, params: ["items": ["a|1", "b", "c"]]),
                   Node(id: "table", type: "table", position: .zero, params: ["columns": "Name"]),
                   Node(id: "join", type: "join", position: .zero, params: [:]),
                   Node(id: "show", type: "view", position: .zero, params: [:])]
        g.edges = [Edge(source: "in", sourceHandle: "items", target: "table", targetHandle: "a"),
                   Edge(source: "in", sourceHandle: "items", target: "join", targetHandle: "items"),
                   Edge(source: "join", sourceHandle: "text", target: "show", targetHandle: "value")]
        return g
    }

    @Test func outputStepsBecomeResults() async {
        let engine = Engine()
        await engine.run(graph())
        let outcomes = Outcome.all(in: graph(), engine: engine)
        #expect(outcomes.map(\.id).sorted() == ["show", "table"])
        guard case .table(let columns, let rows)? = outcomes.first(where: { $0.id == "table" })?.content else {
            Issue.record("the Table step is not a table")
            return
        }
        #expect(columns == ["Name"])
        #expect(rows.map { $0[0].asText } == ["a|1", "b", "c"])
        #expect(outcomes.first { $0.id == "show" }?.value?.asText == "a|1\nb\nc")
    }

    @Test func markdownEscapesTableCells() async {
        let engine = Engine()
        await engine.run(graph())
        let report = ResultsReport(title: "Names", description: "", outcomes: Outcome.all(in: graph(), engine: engine))
        let markdown = report.markdown()
        #expect(markdown.hasPrefix("# Names\n"))
        #expect(markdown.contains("| Name |\n| --- |\n| a\\|1 |"))
    }

    @Test func recordsWithTextAreATableAndScoresAChart() {
        let found: Value = .list([.record([("label", .text("city")), ("text", .text("Boston")), ("confidence", .number(1))])])
        let topics: Value = .list([.record([("name", .text("Travel")), ("score", .number(0.8))])])
        #expect(scored(found.present) != nil)
        #expect(found.present.first?["text"] != nil)
        #expect(topics.present.first?["text"] == nil && scored(topics.present) != nil)
    }
}
