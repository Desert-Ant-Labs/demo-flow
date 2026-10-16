import AppIntents
import Foundation
import Testing
@testable import Flow

/// What a flow from someone else, or a hand-edited file, can hold: numbers
/// out of range, names that clash, files that are not the app's to touch.
@MainActor
@Suite struct SafetyTests {
    private func run(_ def: StepDef, _ inputs: [String: Value], _ params: Params = [:]) async throws -> Outputs {
        try await def.run(StepRun(inputs: inputs, params: def.defaults.merging(params) { $1 }, context: RunContext(id: "t") { _, _ in }))
    }

    @Test func numbersOutOfRangeAreHeld() async throws {
        #expect(JSON.number(.nan).int == nil)
        #expect(JSON.number(.infinity).int == nil)
        #expect(JSON.number(1e300).int == 1_000_000_000_000_000)
        #expect(JSON.number(-2.7).int == -2)
        #expect(JSON.string("4").int == 4)
        let items: Value = .list([.text("a"), .text("b"), .text("c")])
        for n: JSON in [-1, .number(.nan), .number(1e300), .number(-.infinity)] {
            for op in ["firstN", "lastN", "most", "item", "desc"] {
                _ = try await run(LogicSteps.list, ["items": items], ["op": .string(op), "n": n])
            }
        }
        #expect(Recording.turns([[0, 1, .number(.nan)], [0, 1, 2]]).map(\.speaker) == [2])
    }

    @Test func numbersReadTheSameInEveryLanguage() async throws {
        #expect(JSON.number(0.5).string == "0.5")
        #expect(JSON.number(1234).string == "1234")
        let out = try await run(LogicSteps.ifElse, ["value": .number(0.7)], ["op": "above", "operand": 0.5])
        #expect(out["yes"] != nil)
    }

    @Test func everyPatternWritesTheTimeOneWay() async throws {
        let time = #/^\d{2}\.\d{2}\.\d{2}$/#
        let template = try await run(LogicSteps.template, [:], ["template": "{{time}}"])
        #expect(template["text"].asText.contains(time))
        let url = URL(filePath: "/nonexistent/a.txt")
        #expect(FileOps.fill("{{time}}", url: url).contains(time))
        #expect(Placeholders.fill("{{a}} {{b}} {{other}}") { $0 == "a" ? "x" : nil } == "x {{b}} {{other}}")
    }

    @Test func notesDoNotCountTowardProgress() async {
        var graph = Graph()
        graph.nodes = [Node(id: "t", type: "text", position: .zero, params: ["text": "hi"]),
                       Node(id: "n", type: "note", position: .zero, params: ["text": "a note"])]
        let engine = Engine()
        await engine.run(graph)
        #expect(engine.progress == 1)
        engine.reset()
        #expect(engine.progress == 0)
    }

    @Test func aStaleRunNeitherLandsNorWipesTheNewResult() async {
        let runs = Counter()
        // Waits as long as it is told to, and carries on even when cancelled,
        // as a model call does.
        let slow = StepDef(type: "slow", title: "Slow", description: "", category: .logic,
                           outputs: [Port(id: "out", type: .text, label: "Out")]) { run in
            runs.add()
            try? await Task.sleep(for: .milliseconds(run.params["wait"]?.int ?? 0))
            if run.params["fail"]?.bool == true { throw StepError("failed") }
            return ["out": .text(run.params["v"]?.string ?? "")]
        }
        for fails in [false, true] {
            let engine = Engine(steps: ["slow": slow])
            func graph(_ params: Params) -> Graph {
                var g = Graph()
                g.nodes = [Node(id: "s", type: "slow", position: .zero, params: params)]
                return g
            }
            let stale = Task { await engine.run(graph(["v": "old", "wait": 300, "fail": .bool(fails)])) }
            try? await Task.sleep(for: .milliseconds(50))
            await engine.run(graph(["v": "new"]))
            await stale.value
            #expect(engine.state("s").outputs?["out"]?.asText == "new")
            let before = runs.count
            await engine.run(graph(["v": "new"]))
            #expect(runs.count == before, "the new result is still remembered")
        }
    }

    @Test func itemsThatFailAreCounted() async throws {
        let context = RunContext(id: "t") { _, _ in }
        let out = try await InputSteps.photos.run(StepRun(inputs: [:], params: ["samples": [.string(Samples.portraits[0]), "/nonexistent/a.jpg"]],
                                                          context: context))
        #expect(out["photos"]?.present.count == 1)
        #expect(context.note == "1 of 2 photos could not be read")

        let list = StepDef(type: "list", title: "List", description: "", category: .input,
                           outputs: [Port(id: "out", type: .text, label: "Out", each: "item")]) { _ in
            ["out": .list([.text("a"), .text("bad"), .text("c")])]
        }
        let picky = StepDef(type: "picky", title: "Picky", description: "", category: .logic,
                            inputs: [Port(id: "in", type: .text, label: "In")],
                            outputs: [Port(id: "out", type: .text, label: "Out")]) { run in
            if run.inputs["in"].asText == "bad" { throw StepError("bad") }
            return ["out": run.inputs["in"]!]
        }
        var graph = Graph()
        graph.nodes = [Node(id: "l", type: "list", position: .zero, params: [:]), Node(id: "p", type: "picky", position: .zero, params: [:])]
        graph.edges = [Edge(source: "l", sourceHandle: "out", target: "p", targetHandle: "in")]
        let engine = Engine(steps: ["list": list, "picky": picky])
        await engine.run(graph)
        #expect(engine.state("p").status == .done)
        #expect(engine.state("p").note == "1 of 3 items failed")
    }

    @Test func aFlowJustOpenedChangesNoFilesUntilItIsRun() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let thesis = dir.appending(path: "Thesis.md")
        try Data("mine".utf8).write(to: thesis)
        var graph = Graph()
        graph.nodes = [
            Node(id: "t", type: "text", position: .zero, params: ["text": "# Gone"]),
            Node(id: "f", type: "folder", position: .zero, params: ["folder": .string(dir.path), "name": "Thesis", "auto": true]),
            Node(id: "files", type: "files", position: .zero, params: ["files": [.string(thesis.path)]]),
            Node(id: "r", type: "rename", position: .zero, params: ["pattern": "renamed", "mode": "rename", "auto": true]),
        ]
        graph.edges = [Edge(source: "t", sourceHandle: "text", target: "f", targetHandle: "value"),
                       Edge(source: "files", sourceHandle: "files", target: "r", targetHandle: "files")]
        let engine = Engine()
        await engine.run(graph)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["Thesis.md"])
        #expect(try String(contentsOf: thesis, encoding: .utf8) == "mine")
        #expect(engine.state("f").note == "Run the flow to save")
        #expect(engine.state("r").note == "Run the flow to rename")
        #expect(engine.state("r").outputs?["names"]?.present.map(\.asText) == ["renamed.md"], "the plan still shows")

        engine.mayWrite = true
        await engine.run(graph)
        #expect(engine.state("f").note == nil)
        #expect(engine.state("r").note == nil)
        // Saving and renaming run side by side, so either may come first.
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(names.contains("renamed.md"))
        #expect(names.isSubset(of: ["renamed.md", "Thesis.md", "Thesis-2.md"]))
    }

    @Test func aFlowTurnedOnWrites() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        var graph = Graph()
        graph.nodes = [Node(id: "t", type: "text", position: .zero, params: ["text": "note"]),
                       Node(id: "f", type: "folder", position: .zero, params: ["folder": .string(dir.path), "name": "note"])]
        graph.edges = [Edge(source: "t", sourceHandle: "text", target: "f", targetHandle: "value")]
        await Engine(mayWrite: true).run(graph)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["note.txt"])
    }

    @Test func theAppsOwnFoldersAreAlwaysWritable() {
        let context = RunContext(id: "t") { _, _ in }
        #expect(context.mayChange([Library.folder("Converted").appending(path: "a.jpg")]))
        #expect(!context.mayChange([Library.folder("").appending(path: "../../../Documents/a.md")]))
        #expect(!context.mayChange([URL.documentsDirectory.appending(path: "a.md")]))
    }

    @Test func savingNeverReplacesAFileOfYours() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let thesis = dir.appending(path: "Thesis.md")
        try Data("mine".utf8).write(to: thesis)
        let first = try FolderWriter.write(.text("# Draft"), to: dir, name: "Thesis")
        #expect(first.map(\.lastPathComponent) == ["Thesis-2.md"])
        #expect(try String(contentsOf: thesis, encoding: .utf8) == "mine")
        let again = try FolderWriter.write(.text("# Draft 2"), to: dir, name: "Thesis")
        #expect(again == first, "its own file is replaced")

        let a = dir.appending(path: "a"), b = dir.appending(path: "b")
        for (folder, text) in [(a, "one"), (b, "two")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: folder.appending(path: "IMG_0001.txt"))
        }
        let out = dir.appending(path: "out")
        let copied = try FolderWriter.write(.list([.file(a.appending(path: "IMG_0001.txt")), .file(b.appending(path: "IMG_0001.txt"))]),
                                            to: out, name: "x")
        #expect(copied.map(\.lastPathComponent) == ["IMG_0001.txt", "IMG_0001-2.txt"])
        #expect(try copied.map { try String(contentsOf: $0, encoding: .utf8) } == ["one", "two"])
    }

    @Test func convertedPhotosOfOneNameKeepTheirOwnFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = "IMG-\(UUID().uuidString).jpg"
        let photos = try [Samples.portraits[0], Samples.portraits[1]].enumerated().map { i, sample -> Value in
            let folder = dir.appending(path: "\(i)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: Samples.url(sample), to: folder.appending(path: name))
            return .image(try Media.photo(folder.appending(path: name)))
        }
        let first = try #require(ConvertStep.convert(photos[0], to: .png).fileURL)
        let second = try #require(ConvertStep.convert(photos[1], to: .png).fileURL)
        defer { for url in [first, second] { try? FileManager.default.removeItem(at: url) } }
        #expect(first != second)
        #expect(try ConvertStep.convert(photos[0], to: .png).fileURL == first)
    }

    @Test func aFlowThatRepeatsItselfIsRefused() {
        var yaml = "flow: 1\nsteps: []\na0: &a0 [x, x, x, x, x, x, x, x, x, x]\n"
        for i in 1...9 { yaml += "a\(i): &a\(i) [" + Array(repeating: "*a\(i - 1)", count: 10).joined(separator: ", ") + "]\n" }
        #expect(throws: FlowFile.TooBig.self) { try FlowFile.read(yaml) }
    }

    @Test func aLinkThatUnpacksTooFarIsRefused() throws {
        var g = Graph()
        g.nodes = [Node(id: "t", type: "text", position: .zero, params: ["text": .string(String(repeating: "a", count: 3 << 20))])]
        let code = try #require(FlowLink.code(in: FlowLink.url(for: g).absoluteString))
        #expect(throws: FlowLink.BadLink.self) { try FlowLink.graph(from: code) }
        g.nodes[0].params["text"] = "short"
        let small = try #require(FlowLink.code(in: FlowLink.url(for: g).absoluteString))
        #expect(try FlowLink.graph(from: small).node("t")?.params["text"] == "short")
    }

    @Test nonisolated func aFileFromShortcutsStaysInItsOwnFolderAndIsRemoved() async throws {
        let file = IntentFile(data: Data("x".utf8), filename: "../../evil.txt")
        let url = try await ModelAction.local(file) { url in
            #expect(FileManager.default.fileExists(atPath: url.path))
            return url
        }
        #expect(url.lastPathComponent == "evil.txt")
        #expect(url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
                == FileManager.default.temporaryDirectory.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    @Test func aPatternWithoutADateNeverReadsOne() {
        var asked = 0
        _ = Placeholders.fill("{{a}}-{{n}}", at: { asked += 1; return Date() }) { _ in "x" }
        #expect(asked == 0)
        _ = Placeholders.fill("{{date}} {{time}}", at: { asked += 1; return Date() }) { _ in nil }
        #expect(asked == 1)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
}
