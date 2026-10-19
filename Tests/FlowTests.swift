import Foundation
import AppIntents
import CoreText
import Testing
@testable import Flow

/// The suites that run the real models download them first, which needs the
/// network and takes minutes on a new Mac. `FLOW_MODEL_TESTS=1` turns them on.
private let modelTests = Testing.ConditionTrait.enabled(
    if: ProcessInfo.processInfo.environment["FLOW_MODEL_TESTS"] == "1",
    "Set FLOW_MODEL_TESTS=1 to run the real models")

@Suite struct FlowFileTests {
    @Test func everyExampleOpensAndRoundTrips() throws {
        #expect(Example.all.count == 34)
        for example in Example.all {
            let graph = try FlowFile.read(example.text)
            #expect(!graph.nodes.isEmpty, "\(example.id) has no steps")
            #expect(graph.nodes.allSatisfy { $0.def != nil }, "\(example.id) has a step this app does not know")
            let again = try FlowFile.read(FlowFile.write(graph))
            #expect(again.nodes.map(\.id).sorted() == graph.nodes.map(\.id).sorted(), "\(example.id) lost steps")
            #expect(Set(again.edges.map(\.id)) == Set(graph.edges.map(\.id)), "\(example.id) lost wires")
            for n in graph.nodes {
                #expect(again.node(n.id)?.params == n.params, "\(example.id).\(n.id) changed its settings")
            }
        }
    }

    @Test func placedStepsKeepTheirPlace() throws {
        var graph = try FlowFile.read(Example.all[0].text)
        graph.meta.arranged = true
        graph.nodes[0].position = CGPoint(x: 120, y: -40)
        let again = try FlowFile.read(FlowFile.write(graph))
        #expect(again.meta.arranged)
        #expect(again.nodes.first { $0.id == graph.nodes[0].id }?.position == CGPoint(x: 120, y: -40))
    }

    @Test func anUntitledFlowGoesByItsModels() {
        var graph = Example.all[0].graph
        #expect(graph.name == Example.all[0].title)
        graph.meta.title = ""
        #expect(!graph.models.isEmpty)
        #expect(graph.name == graph.autoTitle)
        #expect(graph.name != "Untitled flow")
        #expect(Graph().name == "Untitled flow")
        #expect(Graph().isUntitled && !graph.isUntitled)
    }

    @Test func notAFlowIsRefused() {
        #expect(throws: (any Error).self) { try FlowFile.read("hello: world") }
    }
}

@Suite struct ShareLinkTests {
    /// Made by the web app's own code (pako, with the link dictionary).
    static let webLink = "https://flow.desertant.com/?f=.SxuKR8COHts6emzr6LGto8e2jh7bOnps6yA_thUA"

    @Test func opensALinkFromTheWeb() throws {
        let code = try #require(FlowLink.code(in: Self.webLink))
        let graph = try FlowLink.graph(from: code)
        #expect(graph.meta.title == "Triage a support inbox")
        // The web app's For each step is gone from this one; the rest opens.
        #expect(graph.nodes.count == 9)
    }

    @Test func roundTripsEveryExample() throws {
        for example in Example.all {
            let url = FlowLink.url(for: example.graph)
            let code = try #require(FlowLink.code(in: url.absoluteString))
            let back = try FlowLink.graph(from: code)
            #expect(Set(back.edges.map(\.id)) == Set(example.graph.edges.map(\.id)), "\(example.id)")
        }
    }
}

@MainActor
@Suite struct LogicTests {
    func run(_ def: StepDef, _ inputs: [String: Value], _ params: Params = [:]) async throws -> Outputs {
        try await def.run(StepRun(inputs: inputs, params: def.defaults.merging(params) { $1 }, context: RunContext(id: "t") { _, _ in }))
    }

    @Test func listsGoOnItemByItem() async throws {
        let list: Outputs = ["photos": .list([.text("a"), .text("b")])]
        #expect(Engine.spread(InputSteps.photos, list)["photos"]?.isStream == true)
        let out = try await run(InputSteps.text, [:], ["text": "a\nb\n\nc"])
        #expect(out["lines"]?.present.map(\.asText) == ["a", "b", "c"])
        #expect(Engine.spread(InputSteps.text, out)["text"]?.isStream == false)
    }

    @Test func ifElseKeepsHoles() async throws {
        let out = try await run(LogicSteps.ifElse, ["value": .stream([.text("en"), .text("fr"), nil])], ["op": "equals", "operand": "en"])
        #expect(out["yes"]?.items.map { $0?.asText } == ["en", nil, nil])
        #expect(out["no"]?.items.map { $0?.asText } == [nil, "fr", nil])
    }

    @Test func mergeFillsFromEither() async throws {
        let out = try await run(LogicSteps.merge, ["a": .stream([.text("x"), nil]), "b": .stream([nil, .text("y")])])
        #expect(out["value"]?.present.map(\.asText) == ["x", "y"])
    }

    @Test func listSortsByAnotherList() async throws {
        let out = try await run(LogicSteps.list, ["items": .list([.text("a"), .text("b"), .text("c")]),
                                                  "by": .list([.number(0.2), .number(0.9), .number(0.5)])], ["op": "desc", "n": 2])
        #expect(out["result"]?.present.map(\.asText) == ["b", "c"])
    }

    @Test func pickBestTakesTheTopScore() async throws {
        let out = try await run(LogicSteps.best, ["items": .list([.text("a"), .text("b")]), "scores": .list([.number(1), .number(3)])])
        #expect(out["best"]?.asText == "b")
    }

    @Test func templateFillsItemByItem() async throws {
        let out = try await run(LogicSteps.template, ["a": .stream([.text("fr"), .text("de")])], ["template": "Send to the {{a|lang}} team"])
        #expect(out["text"]?.present.map(\.asText) == ["Send to the French team", "Send to the German team"])
    }
}

@Suite struct FolderWriterTests {
    @Test func writesTablesAndText() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rows: Value = .list([.record([("name", .text("Ann")), ("age", .number(30))]), .record([("name", .text("Bo, Jr")), ("age", .number(4))])])
        let csv = try FolderWriter.write(rows, to: dir, name: "people")
        #expect(csv.map(\.lastPathComponent) == ["people.csv"])
        #expect(try String(contentsOf: csv[0], encoding: .utf8) == "name,age\nAnn,30\n\"Bo, Jr\",4")
        let md = try FolderWriter.write(.text("# Notes\n- one"), to: dir, name: "notes")
        #expect(md.map(\.lastPathComponent) == ["notes.md"])
    }

    @Test func samplesWriteNothing() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let def = OutputSteps.folder
        let params = def.defaults.merging(["folder": .string(dir.path)]) { $1 }
        for samples in [true, false] {
            _ = try await def.run(StepRun(inputs: ["value": .text("Hello")], params: params,
                                          context: RunContext(id: "t", samples: samples, mayWrite: true) { _, _ in }))
            #expect(FileManager.default.fileExists(atPath: dir.path) == !samples)
        }
    }

    /// The templates that write files on every run open on their samples, so
    /// opening one leaves your folders alone.
    @Test func templatesThatWriteOpenOnSamples() throws {
        for id in ["file-receipts-as-they-arrive", "voice-memo-notes"] {
            let example = try #require(Example.all.first { $0.id == id })
            #expect(example.graph.runsOnSamples, "\(id)")
        }
    }

    /// The samples live inside the app and can't be renamed, so a template
    /// that renames in place opens on nothing until a real file arrives.
    @Test func templatesThatRenameInPlaceHaveNoSamples() {
        for example in Example.all {
            let graph = example.graph
            guard graph.nodes.contains(where: { $0.type == "rename" && $0.params["mode"]?.string == "rename" }) else { continue }
            #expect(!graph.runsOnSamples, "\(example.id)")
        }
    }
}

@Suite struct FileOpsTests {
    @Test func namesFollowThePattern() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let urls = try (1...12).map { i -> URL in
            let url = dir.appending(path: "IMG_\(i).JPG")
            try Data().write(to: url)
            return url
        }
        let names = FileOps.names(for: urls, pattern: "{{a}} {{n}}", a: urls.map { _ in .list([.text("Beach"), .text("Sky")]) })
        #expect(names.first == "Beach 01.jpg")
        #expect(names.last == "Beach 12.jpg")
        let dated = FileOps.names(for: [urls[0]], pattern: "{{date}}")[0]
        #expect(dated.contains(#/^\d{4}-\d{2}-\d{2}\.jpg$/#))
        #expect(FileOps.names(for: [urls[0], urls[1]], pattern: "same") == ["same.jpg", "same-2.jpg"])
    }

    @Test func copiesWithoutOverwriting() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "a.txt")
        try Data("a".utf8).write(to: file)
        let target = dir.appending(path: "out/b.txt")
        let first = try FileOps.apply([file], to: [target], .copy)
        let second = try FileOps.apply([file], to: [target], .copy)
        #expect(first[0].lastPathComponent == "b.txt")
        #expect(second[0].lastPathComponent == "b.txt")
        try Data("changed".utf8).write(to: file)
        let third = try FileOps.apply([file], to: [target], .copy)
        #expect(third[0].lastPathComponent == "b-2.txt")
    }
}

@Suite struct ConvertTests {
    @Test func convertsAPhotoToEachFormat() throws {
        let photo = Value.image(try Media.photo(Samples.url(Samples.portraits[0])))
        for format in FileFormat.of(.photo) {
            let out = try ConvertStep.convert(photo, to: format)
            let url = try #require(out.fileURL)
            #expect(url.pathExtension == format.ext)
            #expect(try Media.photo(url).width > 0, "\(format) did not read back")
        }
    }

    @Test func convertsAudioToEachFormat() async throws {
        let clip = Value.audio(try await Media.audio(Samples.url(Samples.audio[0].path)))
        for format in FileFormat.of(.audio) {
            guard case .file(let url) = try ConvertStep.convert(clip, to: format) else { Issue.record("\(format) gave no file"); continue }
            #expect(url.pathExtension == format.ext)
            let back = try await Media.audio(url)
            #expect(abs(back.duration - clip.audio!.duration) < 0.2, "\(format) changed the length")
        }
    }

    @Test func convertsTextAndTables() throws {
        for format in FileFormat.of(.text) {
            let out = try ConvertStep.convert(.text("Hello, Flow"), to: format)
            #expect(try String(contentsOf: try #require(out.fileURL), encoding: .utf8).contains("Hello"), "\(format)")
        }
        let table = Value.list([.record([("name", .text("Ana")), ("score", .number(0.9))])])
        let csv = try String(contentsOf: try #require(ConvertStep.convert(table, to: .csv).fileURL), encoding: .utf8)
        #expect(csv == "name,score\nAna,0.9")
        #expect(throws: StepError.self) { try ConvertStep.convert(.text("Hi"), to: .jpeg) }
    }
}

/// Each Shortcuts action as Shortcuts calls it, on the real models. Slow the
/// first time on a Mac, while the models download and get ready.
@Suite(.serialized, modelTests) struct ShortcutsActionTests {
    private func file(_ path: String) -> IntentFile {
        IntentFile(fileURL: Samples.url(path), filename: Samples.url(path).lastPathComponent)
    }

    @Test func voiceActions() async throws {
        var voz = TranscribeAudio()
        voz.audio = file("/samples/jfk.wav")
        let text = try #require(try await voz.perform().value)
        #expect(text.localizedCaseInsensitiveContains("country"), "Voz heard: \(text)")

        var ear = SpokenLanguage()
        ear.audio = file("/samples/jfk.wav")
        #expect(try await ear.perform().value == "English")

        var clear = CleanAudio()
        clear.audio = file("/samples/jfk.wav")
        let cleaned = try #require(try await clear.perform().value)
        #expect(cleaned.filename.hasSuffix(".wav") && cleaned.data.count > 10_000)
    }

    @Test func textActions() async throws {
        let message = "Hi, I'm Sarah Collins. Please call me at +1 312 555 0187 about my order."
        var redact = RedactText()
        redact.text = message
        let masked = try #require(try await redact.perform().value)
        #expect(!masked.contains("Collins") && !masked.contains("555"), "Redact gave: \(masked)")

        var tongue = WrittenLanguage()
        tongue.text = "Bonjour, je suis Claire. Ma livraison n'est jamais arrivée."
        #expect(try await tongue.perform().value == "French")

        var gist = TextTopic()
        gist.text = "The striker scored twice in the second half and the team won the league."
        let topic = try #require(try await gist.perform().value)
        #expect(!topic.isEmpty, "Gist gave no topic")

        var emo = SuggestEmoji()
        emo.text = "Happy birthday! Let's celebrate tonight"
        emo.limit = 2
        let emoji = try #require(try await emo.perform().value)
        #expect(!emoji.isEmpty, "Emo gave no emoji")
    }

    @Test func photoActions() async throws {
        var moderator = CheckPhoto()
        // A mountain view. Moderator flags some photos of clothed people,
        // which is the model's to fix, not this action's.
        moderator.photo = file("/samples/photos/001.jpg")
        #expect(try await moderator.perform().value == true)

        var eye = ReadPhoto()
        eye.photo = file("/samples/two-women-taking-selfie.jpg")
        eye.question = .faces
        #expect(try await eye.perform().value == "2")
        eye.question = .smile
        let smile = try #require(try await eye.perform().value)
        #expect(smile.hasSuffix("%"), "Eye gave: \(smile)")
        eye.question = .subject
        #expect(!(try await eye.perform().value ?? "").isEmpty)
    }
}

@Suite struct KindTests {
    /// The editor's stricter reading of what fits must not flag a wire in an
    /// example as wrong.
    @MainActor @Test func everyExampleWireFits() throws {
        for example in Example.all {
            let g = example.graph
            for e in g.edges {
                guard let from = g.node(e.source), let out = from.def?.outputs.first(where: { $0.id == e.sourceHandle }),
                      let to = g.node(e.target), let input = to.def?.inputs.first(where: { $0.id == e.targetHandle })
                else { continue }
                #expect(accepts(input, of: to.def, outputKind(from, out, session: nil)), "\(example.id): \(e.id)")
            }
        }
    }

    @MainActor @Test func aPhotoTypeIsNoTextForGist() {
        let eye = Node(id: "eye", type: "eye", position: .zero, params: [:])
        let type = Steps.byType["eye"]!.outputs.first { $0.id == "type" }!
        let gist = Steps.byType["gist"]!, template = Steps.byType["template"]!
        #expect(!accepts(gist.inputs[0], of: gist, outputKind(eye, type, session: nil)))
        #expect(accepts(template.inputs[0], of: template, outputKind(eye, type, session: nil)))
    }
}

@Suite struct ReadTextTests {
    @Test func readsTheWordsInAPhoto() async throws {
        let size = CGSize(width: 900, height: 240)
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(.white); ctx.fill(CGRect(origin: .zero, size: size))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Invoice 4417 for Sarah Collins",
            attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 56, nil), .foregroundColor: CGColor.black]))
        ctx.textPosition = CGPoint(x: 30, y: 100)
        CTLineDraw(line, ctx)
        let photo = Media.photo(ctx.makeImage()!, name: "invoice.png")
        let out = try await ReadTextStep.def.run(StepRun(inputs: ["image": .image(photo)], params: [:], context: RunContext(id: "t") { _, _ in }))
        #expect(out["text"].asText.contains("Sarah Collins"), "Read: \(out["text"].asText)")
    }
}

@Suite struct StepOrderTests {
    /// A step put between two others, ahead of the one it now feeds, lists in
    /// that gap, not after the flow's other branches.
    @Test func anInsertedStepListsWhereItWent() throws {
        var g = Example.all.first { $0.id == "voice-memo" }!.graph
        let ear = g.node("ear")!
        g.nodes.append(Node(id: "clear2", type: "clear", position: CGPoint(x: ear.position.x - 1, y: ear.position.y), params: [:]))
        g.connect(Edge(source: "in", sourceHandle: "audio", target: "clear2", targetHandle: "audio"))
        g.connect(Edge(source: "clear2", sourceHandle: "audio", target: "ear", targetHandle: "audio"))
        let order = g.ordered.map(\.id)
        #expect(Array(order.prefix(3)) == ["in", "clear2", "ear"], "\(order)")
    }
}

@Suite struct UpstreamTests {
    /// Voz fits after Ear: Ear gives a language, but the audio Ear listened
    /// to is one step up, and Voz takes that.
    @MainActor @Test func vozAfterEarTakesTheAudioAbove() {
        let g = Example.all.first { $0.id == "voice-memo" }!.graph
        let voz = Steps.byType["voz"]!
        let sources = upstreamOutputs(from: g.node("ear")!, in: g, session: nil)
        let pick = nearest(for: voz.inputs[0], of: voz, in: sources)
        #expect(pick?.node.id == "in" && pick?.port.id == "audio")
        let gist = Steps.byType["gist"]!
        #expect(nearest(for: gist.inputs[0], of: gist, in: sources) == nil)
    }
}

/// Whole templates through the engine, on the real models, with no For each:
/// a list goes on one item at a time by default.
@MainActor @Suite(.serialized, modelTests) struct TemplateRunTests {
    private func run(_ id: String) async -> (Graph, Engine) {
        let g = Example.all.first { $0.id == id }!.graph
        let engine = Engine()
        await engine.run(g)
        return (g, engine)
    }

    @Test func theInboxRoutesEachTicket() async {
        let (g, engine) = await run("inbox")
        for n in g.nodes { #expect(engine.state(n.id).status != .error, "\(n.id): \(engine.state(n.id).error ?? "")") }
        let yes = engine.state("if").outputs?["yes"]?.present.count ?? 0
        let no = engine.state("if").outputs?["no"]?.present.count ?? 0
        #expect(yes + no == 7, "every ticket went one way: \(yes) if, \(no) else")
        #expect(yes == 4)
    }

    @Test func theSmilesFindSmiles() async {
        let (g, engine) = await run("smiles")
        for n in g.nodes { #expect(engine.state(n.id).status != .error, "\(n.id): \(engine.state(n.id).error ?? "")") }
        #expect(engine.state("eye").count == 12, "Eye ran once per photo")
        #expect((engine.state("show").inputs["photos"]?.present.count ?? 0) > 0)
    }
}

@MainActor @Suite struct RowTests {
    /// The clear-out reads straight down: Eye, then the Split and its sides, with nothing in between to explain.
    @Test func theClearOutReadsStraightDown() {
        let g = Example.all.first { $0.id == "clearout" }!.graph
        let ids = StepRows(graph: g, ordered: g.ordered.filter { $0.type != "note" }).rows.map(\.id)
        #expect(ids.first == "in")
        #expect(ids.firstIndex(of: "eye")! < ids.firstIndex(of: "if")!)
        #expect(ids.contains("if.if") && ids.contains("if.else"))
        #expect(!ids.contains { $0.hasSuffix(".each") || $0.hasSuffix(".together") })
    }
}
