import AVFoundation
import EchoCancel
import Foundation
import Testing
@testable import Flow

@MainActor
@Suite struct LiveNotesTests {
    private func run(_ def: StepDef, _ params: Params) async throws -> Outputs {
        try await def.run(StepRun(inputs: [:], params: def.defaults.merging(params) { $1 }, context: RunContext(id: "t") { _, _ in }))
    }

    private let take = Take(audio: nil, transcript: Transcript(
        text: "Pricing first. Then hiring.",
        words: [.init(text: "Pricing", start: 0, end: 0.4), .init(text: "first.", start: 0.4, end: 0.8)]))

    @Test func aTranscriptComesOutOfTheRecordStepWithoutAudio() async throws {
        let out = try await run(InputSteps.record, Recording.params(take))
        #expect(out["audio"] == nil)
        #expect(out["text"]?.asText == "Pricing first. Then hiring.")
        #expect(out["sentences"]?.present.count == 2)
        #expect(out["words"]?.present.count == 2)
    }

    @Test func aMeetingTranscribesAndKeepsNoRecordingUnlessAsked() {
        let meeting: Params = ["source": "meeting"]
        #expect(Recording.transcribes(meeting))
        #expect(!Recording.keeps(meeting))
        #expect(Recording.keeps(meeting.merging(["keep": .bool(true)]) { $1 }))
        let microphone: Params = ["source": "microphone"]
        #expect(!Recording.transcribes(microphone))
        #expect(Recording.keeps(microphone))
        #expect(Recording.keeps(meeting.merging(["transcribe": .bool(false)]) { $1 }), "With no words, the recording is all there is")
    }

    @Test func theMeetingTemplateStartsFromALiveTranscriptAndRunsVoz() throws {
        let g = Example.all.first { $0.id == "meeting" }!.graph
        let input = try #require(TriggerCenter.input(of: g))
        #expect(input.type == "call")
        #expect(Recording.options(input.params).transcribes)
        #expect(!Recording.options(input.params).keepsRecording)
        #expect(g.models.contains(.voz))
        #expect(Example.all.first { $0.id == "meeting" }!.models.contains(.voz))
    }

    @Test func aCallsWordsFillTheFlowSoNothingIsTranscribedAgain() throws {
        var g = Example.all.first { $0.id == "meeting" }!.graph
        try TriggerCenter.fill(&g, with: take)
        #expect(g.node("in")?.params["transcript"]?.string == "Pricing first. Then hiring.")
        #expect(g.node("in")?.params["file"] == nil)
        let back = try FlowFile.read(FlowFile.write(g))
        #expect(Recording.words(back.node("in")?.params["words"]).count == 2)
    }

    @Test func aFlowThatNeedsTheRecordingSaysSoWhenItWasNotKept() {
        var g = Graph()
        g.nodes = [Node(id: "a", type: "audio", position: .zero, params: [:])]
        #expect(throws: StepError.self) { try TriggerCenter.fill(&g, with: take) }
    }

    @Test func aNoteIsSavedUnderItsDateAndTopic() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let params: Params = ["folder": .string(dir.path), "name": "{{date}} {{a}}"]
        _ = try await OutputSteps.folder.run(StepRun(inputs: ["value": .text("# Pricing\n\nWords")], params: OutputSteps.folder.defaults.merging(params) { $1 },
                                                     context: RunContext(id: "t", mayWrite: true) { _, _ in }))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty ?? true, "Nothing is written before the topic is known")
        _ = try await OutputSteps.folder.run(StepRun(inputs: ["value": .text("# Pricing\n\nWords"), "a": .text("Pricing")],
                                                     params: OutputSteps.folder.defaults.merging(params) { $1 },
                                                     context: RunContext(id: "t", mayWrite: true) { _, _ in }))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["\(Placeholders.now("date")) Pricing.md"])
    }

    @Test func liveAudioIsMixedAndHandedOnAtVozsRate() async throws {
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        let feed = AudioFeed(continuation)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        for i in 0..<48_000 { buffer.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.5 }
        feed.push(buffer)
        feed.finish()
        var count = 0
        for await chunk in stream { count += chunk.count }
        #expect(abs(count - 16_000) < 200)
    }
}

/// Voz, live, on a real recording fed a tenth of a second at a time.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FLOW_MODEL_TESTS"] == "1", "Set FLOW_MODEL_TESTS=1 to run the real models"))
struct LiveVozTests {
    @Test func vozWritesWordsAsTheAudioComes() async throws {
        let clip = try await MediaCache.shared.audio(Samples.url("/samples/jfk.wav"))
        let transcript = LiveTranscript()
        let format = AVAudioFormat(standardFormatWithSampleRate: clip.sampleRate, channels: 1)!
        let step = Int(clip.sampleRate / 10)
        for start in stride(from: 0, to: clip.samples.count, by: step) {
            let part = Array(clip.samples[start..<min(clip.samples.count, start + step)])
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(part.count)))
            buffer.frameLength = AVAudioFrameCount(part.count)
            part.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: part.count) }
            transcript.feed.push(buffer)
        }
        let result = await transcript.finish()
        #expect(result.text.localizedCaseInsensitiveContains("country"), "\(result.text)")
        #expect(!result.words.isEmpty)
    }

    /// A guest on the call, with speakers on: the call side gets their words,
    /// and the room, once AEC3 has taken out their echo, gets none of them.
    @Test func theGuestIsHeardOnTheCallAndNotInTheRoom() async throws {
        let clip = try await MediaCache.shared.audio(Samples.url("/samples/jfk.wav"))
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let converter = try #require(AVAudioConverter(from: AVAudioFormat(standardFormatWithSampleRate: clip.sampleRate, channels: 1)!, to: format))
        let source = try #require(AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(clip.samples.count)))
        source.frameLength = source.frameCapacity
        clip.samples.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: clip.samples.count) }
        let out = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(clip.samples.count) * 48_000 / clip.sampleRate) + 4_800))
        nonisolated(unsafe) var given = false
        try converter.convert(to: out, error: nil) { _, status in
            if given { status.pointee = .endOfStream; return nil }
            given = true
            status.pointee = .haveData
            return source
        }
        let n = Int(out.frameLength) / 480 * 480
        let call = Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: n))
        // The room: the call off the speakers, 25 ms later, quieter, and smeared.
        var room = call.indices.map { i in 0.3 * (i >= 1_200 ? call[i - 1_200] : 0) + 0.12 * (i >= 1_900 ? call[i - 1_900] : 0) }
        try #require(EchoCanceller(sampleRate: 48_000)).cancel(&room, played: call)

        let transcript = LiveTranscript(RecordingOptions(transcribes: true, labelsSpeakers: true, guests: ["John Kennedy"]), sides: [.room, .call])
        for start in stride(from: 0, to: n, by: 4_800) {
            for (side, samples) in [(Side.room, room), (.call, call)] {
                let part = Array(samples[start..<min(n, start + 4_800)])
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(part.count)))
                buffer.frameLength = AVAudioFrameCount(part.count)
                part.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: part.count) }
                transcript.feeds[side]!.push(buffer)
            }
        }
        let result = await transcript.finish()
        #expect(result.text.localizedCaseInsensitiveContains("country"), "\(result.text)")
        #expect(result.words.allSatisfy { $0.speaker.map { Side.of($0) == .call } ?? false }, "\(result.labeled)")
        #expect(result.labeled.hasPrefix("John Kennedy: "), "\(result.labeled)")
    }
}
