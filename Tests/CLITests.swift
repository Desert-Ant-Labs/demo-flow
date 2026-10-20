import AVFoundation
import Foundation
import Testing
import Yams
@testable import Flow

/// What the desertant CLI says about its flow steps, from `da schema --json`,
/// and the templates it ships. When the CLI releases, refresh Fixtures/CLI
/// and port whatever these tests flag, so a flow runs the same in both.
private let fixtures = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/CLI")

private struct CLIStep: Sendable {
    let type: String
    let inputs: [(id: String, type: String)]
    let outputs: [(id: String, type: String)]
    let settings: [String: JSON]

    static let all: [CLIStep] = {
        let data = try! Data(contentsOf: fixtures.appending(path: "schema.json"))
        let steps = (try! JSONSerialization.jsonObject(with: data) as! [String: Any])["flowSteps"] as! [[String: Any]]
        func ports(_ list: Any?) -> [(String, String)] { (list as! [[String: Any]]).map { ($0["id"] as! String, $0["type"] as! String) } }
        return steps.map { CLIStep(type: $0["type"] as! String, inputs: ports($0["inputs"]), outputs: ports($0["outputs"]),
                                   settings: ($0["settings"] as? [String: Any] ?? [:]).mapValues(JSON.init(any:))) }
    }()
}

@Suite struct CLITests {
    @Test(arguments: CLIStep.all.map(\.type))
    func everyStepHasTheCLIsPorts(_ type: String) throws {
        let cli = CLIStep.all.first { $0.type == type }!
        let def = try #require(Steps.byType[type], "Flow has no \(type) step")
        for (id, kind) in cli.inputs {
            #expect(def.inputs.first { $0.id == id }?.type.rawValue == kind, "\(type) takes \(id) as \(kind)")
        }
        for (id, kind) in cli.outputs {
            #expect(def.outputs.first { $0.id == id }?.type.rawValue == kind, "\(type) gives \(id) as \(kind)")
        }
        // An input left out of `uses` takes a step's first output that fits.
        let shared = Set(cli.outputs.map(\.id))
        #expect(def.outputs.map(\.id).filter(shared.contains) == cli.outputs.map(\.id), "\(type) lists its outputs in the CLI's order")
    }

    /// A setting the CLI leaves empty has no default to agree on.
    @Test(arguments: CLIStep.all.map(\.type))
    func everyDefaultIsTheCLIs(_ type: String) throws {
        let cli = CLIStep.all.first { $0.type == type }!
        let def = try #require(Steps.byType[type])
        for (key, given) in cli.settings {
            guard ![.null, .string(""), .array([])].contains(given) else { continue }
            #expect(def.defaults[key] == given, "\(type).\(key) defaults to \(given) in the CLI")
        }
    }

    @Test(arguments: try FileManager.default.contentsOfDirectory(atPath: fixtures.appending(path: "templates").path).sorted())
    func everyTemplateOpensWired(_ name: String) throws {
        let text = try String(contentsOf: fixtures.appending(path: "templates/\(name)"), encoding: .utf8)
        let steps = try #require(try Yams.load(yaml: text) as? [String: Any])["steps"] as? [Any]
        let graph = try FlowFile.read(text)
        #expect(graph.nodes.count == steps?.count, "\(name) lost a step")
        for edge in graph.edges {
            #expect(graph.node(edge.source)?.def?.outputs.contains { $0.id == edge.sourceHandle } == true, "\(name): \(edge.source).\(edge.sourceHandle)")
            #expect(graph.node(edge.target)?.def?.inputs.contains { $0.id == edge.targetHandle } == true, "\(name): \(edge.target).\(edge.targetHandle)")
        }
        for node in graph.nodes {
            let wired = Set(graph.incoming(node.id).map(\.targetHandle))
            for port in node.def?.inputs ?? [] where !port.optional {
                #expect(wired.contains(port.id), "\(name): \(node.id).\(port.id) is unwired")
            }
        }
    }
}

private let modelTests = Testing.ConditionTrait.enabled(
    if: ProcessInfo.processInfo.environment["FLOW_MODEL_TESTS"] == "1",
    "Set FLOW_MODEL_TESTS=1 to run the real models")

/// The CLI's templates, run in Flow on a talking video.
@MainActor @Suite(.serialized, modelTests) struct CLITemplateRunTests {
    private func run(_ template: String, on file: URL) async throws -> (Graph, Engine) {
        var graph = try FlowFile.read(String(contentsOf: fixtures.appending(path: "templates/\(template).yml"), encoding: .utf8))
        graph.nodes[0].params["file"] = .string(file.path)
        graph.nodes[0].params["sample"] = nil
        let engine = Engine()
        await engine.run(graph)
        for node in graph.nodes { #expect(engine.state(node.id).status != .error, "\(node.id): \(engine.state(node.id).error ?? "")") }
        return (graph, engine)
    }

    private func talkingVideo() async throws -> URL {
        try await grayVideo(CGSize(width: 1080, height: 1920), seconds: 20, sound: Samples.url(Samples.audio[0].path))
    }

    @Test func studioSoundKeepsThePicture() async throws {
        let (_, engine) = try await run("studio-sound", on: try await talkingVideo())
        let clean = try #require(engine.state("clear").outputs?["audio"]?.audio?.file)
        #expect(try await Cutter.info(clean).hasVideo)
    }

    @Test func podcastClipsAreCutWithCaptionsBurnedIn() async throws {
        let (_, engine) = try await run("podcast-clips", on: try await talkingVideo())
        let clips = engine.state("clips").outputs?["files"]?.present.compactMap(\.fileURL) ?? []
        #expect(!clips.isEmpty)
        for clip in clips {
            #expect(try await Cutter.info(clip).size == CGSize(width: 1080, height: 1920))
            let (frame, _) = try await AVAssetImageGenerator(asset: AVURLAsset(url: clip)).image(at: CMTime(seconds: 1, preferredTimescale: 600))
            #expect(brightPixels(frame, rows: 1000..<1920) > 0, "\(clip.lastPathComponent) has its captions")
        }
    }

    @Test func captionsAndFillersComeFromTheRecording() async throws {
        let audio = Samples.url(Samples.audio[0].path)
        let (_, captioned) = try await run("transcript-and-captions", on: audio)
        #expect(captioned.state("captions").outputs?["srt"]?.asText.hasPrefix("1\n00:00:") == true)
        let (_, fillers) = try await run("filler-words", on: audio)
        #expect(fillers.state("uhm").outputs?["count"]?.asNumber != nil)
    }
}
