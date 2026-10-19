import Foundation
import Testing
@testable import Flow

@MainActor
@Suite struct AskTests {
    /// A list of three texts, one at a time, into Ask, and Yes and No into a Join each.
    private func graph(_ ask: Params, items: [String] = ["a", "b", "c"]) -> Graph {
        var g = Graph()
        g.nodes = [Node(id: "in", type: "textlist", position: .zero, params: ["items": .array(items.map { .string($0) })]),
                   Node(id: "ask", type: "ask", position: .zero, params: AskStep.def.defaults.merging(ask) { $1 }),
                   Node(id: "kept", type: "join", position: .zero, params: [:]),
                   Node(id: "left", type: "join", position: .zero, params: [:])]
        g.edges = [Edge(source: "in", sourceHandle: "items", target: "ask", targetHandle: "value"),
                   Edge(source: "ask", sourceHandle: "yes", target: "kept", targetHandle: "items"),
                   Edge(source: "ask", sourceHandle: "no", target: "left", targetHandle: "items")]
        return g
    }

    /// Runs the flow until Ask asks, answers, and waits for the rest.
    private func run(_ engine: Engine, _ g: Graph, answer: (Question) -> Answer) async throws -> Question {
        let running = Task { await engine.run(g) }
        let q = try await question(engine)
        engine.answer("ask", answer(q))
        await running.value
        return q
    }

    private func question(_ engine: Engine) async throws -> Question {
        for _ in 0..<500 {
            if let q = engine.questions["ask"] { return q }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw StepError("Ask never asked")
    }

    @Test func yesSendsEverythingOnAndNoSendsNothing() async throws {
        let engine = Engine()
        let q = try await run(engine, graph(["question": "Keep {{items}}, all {{count}}?"])) { _ in .yes }
        #expect(q.text == "Keep 3 items, all 3?")
        #expect(q.items.map(\.asText) == ["a", "b", "c"])
        #expect(engine.state("kept").outputs?["text"]?.asText == "a\nb\nc")
        #expect(engine.state("left").status == .skipped)
    }

    @Test func pickedItemsGoOnAndTheRestGoToNo() async throws {
        let engine = Engine()
        _ = try await run(engine, graph(["kind": "pick"])) { _ in .picked([0, 2]) }
        #expect(engine.state("kept").outputs?["text"]?.asText == "a\nc")
        #expect(engine.state("left").outputs?["text"]?.asText == "b")
    }

    @Test func aChosenAnswerComesOutAsText() async throws {
        let out = try AskStep.outputs(.chose("Travel"), value: nil, slots: [], kind: .choose)
        #expect(out["answer"]?.asText == "Travel")
        #expect(out["yes"]?.asText == "Travel")
        let engine = Engine()
        var g = graph(["kind": "choose"])
        g.nodes[1].params["options"] = ""
        await engine.run(g)
        #expect(engine.state("ask").error == "Add the answers to choose from")
    }

    @Test func anAnswerIsKeptWhenTheFlowRunsAgain() async throws {
        let engine = Engine()
        let g = graph([:])
        _ = try await run(engine, g) { _ in .yes }
        await engine.run(g, force: true)
        #expect(engine.questions.isEmpty)
        #expect(engine.state("kept").status == .done)
    }

    @Test func aNewValueTakesBackTheOldQuestion() async throws {
        let engine = Engine()
        let first = Task { await engine.run(graph([:])) }
        let old = try await question(engine)
        let second = Task { await engine.run(graph([:], items: ["x"])) }
        var new = old
        for _ in 0..<500 where new.id == old.id {
            try await Task.sleep(for: .milliseconds(10))
            new = engine.questions["ask"] ?? old
        }
        #expect(new.id != old.id)
        #expect(new.items.map(\.asText) == ["x"])
        #expect(engine.questions.count == 1)
        engine.answer("ask", .no)
        await first.value
        await second.value
        #expect(engine.state("left").outputs?["text"]?.asText == "x")
    }

    @Test func stoppingFailsTheStep() async throws {
        let engine = Engine()
        _ = try await run(engine, graph([:])) { _ in .stop }
        #expect(engine.state("ask").error == "Stopped at this question")
        #expect(engine.state("kept").status == .skipped)
    }

    @Test func aRunNobodyWatchesGoesOnAfterItsWait() async throws {
        let engine = Engine()
        engine.attended = false
        // 30ms, in minutes.
        await engine.run(graph(["wait": .number(0.0005), "fallback": "yes"]))
        #expect(engine.questions.isEmpty)
        #expect(engine.state("kept").outputs?["text"]?.asText == "a\nb\nc")
        #expect(engine.state("ask").note?.hasPrefix("Nobody answered") == true)
    }

    @Test func aRunNobodyWatchesStillTakesAnAnswerInTime() async throws {
        let engine = Engine()
        engine.attended = false
        var asked: Question?
        engine.asked = { asked = $0 }
        _ = try await run(engine, graph(["wait": 60, "fallback": "stop"])) { _ in .no }
        #expect(asked?.deadline != nil)
        #expect(asked?.fallback == .stop)
        #expect(engine.state("left").status == .done)
    }

    @Test func fallbacksFitTheKindOfQuestion() {
        #expect(AskStep.fallback(.yes, kind: .pick, count: 3, options: [], suggestion: "") == .picked([0, 1, 2]))
        #expect(AskStep.fallback(.no, kind: .pick, count: 3, options: [], suggestion: "") == .picked([]))
        #expect(AskStep.fallback(.yes, kind: .choose, count: 0, options: ["A", "B"], suggestion: "") == .chose("A"))
        #expect(AskStep.fallback(.yes, kind: .type, count: 0, options: [], suggestion: "Draft") == .typed("Draft"))
        #expect(AskStep.fallback(.stop, kind: .confirm, count: 0, options: [], suggestion: "") == .stop)
    }

    @Test func itemsAreCountedByWhatTheyAre() {
        #expect(AskStep.counted([]) == "this")
        #expect(AskStep.counted([.text("a")]) == "1 item")
        #expect(AskStep.counted([.file(URL(filePath: "/a")), .file(URL(filePath: "/b"))]) == "2 files")
    }
}
