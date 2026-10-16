import AVFoundation
import Foundation
import Observation

/// What a recording leaves: the audio, when it is kept, and the words, when
/// they were transcribed as it recorded.
struct Take: Sendable {
    var audio: URL?
    var transcript: Transcript?

    var isEmpty: Bool { audio == nil && (transcript?.text.isEmpty ?? true) }
}

/// How a recording is made: kept as a file, transcribed live, or both.
struct RecordingOptions: Sendable {
    init(keepsRecording: Bool = true, transcribes: Bool = false, labelsSpeakers: Bool = false, vocabulary: [String] = [], guests: [String] = []) {
        self.keepsRecording = keepsRecording
        self.transcribes = transcribes
        self.labelsSpeakers = labelsSpeakers
        self.vocabulary = vocabulary
        self.guests = guests
    }

    var keepsRecording = true
    var transcribes = false
    /// Who tells the voices apart as it records.
    var labelsSpeakers = false
    /// Names Voz should expect, as the people on a call.
    var vocabulary: [String] = []
    /// Who was invited to the call besides you, to name the voice on it.
    var guests: [String] = []
}

/// Voz transcribing a recording while it is made. The audio goes to Voz and
/// nowhere else, so with the recording not kept, nothing heard is written to
/// disk; only the words are.
///
/// A call is heard as two sides, the room and the call (see `Side`), each
/// with its own Voz session and its own Who, and their words are put back
/// together in the order they were said.
@MainActor
@Observable
final class LiveTranscript {
    /// The words Voz has settled.
    private(set) var committed = ""
    /// The words at the end that Voz may still change.
    private(set) var tentative = ""
    private(set) var failure: String?
    /// Every side's words so far, in the order they were said, each with its
    /// voice when voices are told apart.
    private(set) var said: [Heard.Said] = []
    /// The names given to voices while the call records.
    private(set) var given: [Int: String] = [:]
    /// Who was invited besides you.
    let guests: [String]
    let sides: [Side]
    private let labelsSpeakers: Bool
    @ObservationIgnored private var heard: [Side: Heard] = [:]

    /// Takes each side's audio on any queue and hands it to Voz in order.
    nonisolated let feeds: [Side: AudioFeed]
    /// The microphone's, for a recording that is only that.
    nonisolated var feed: AudioFeed { feeds[.room]! }
    @ObservationIgnored private var result: Task<Transcript, Never>?
    /// The audio, held for Voz until `begin`.
    @ObservationIgnored private var streams: [Side: AsyncStream<[Float]>]?
    private let options: RecordingOptions

    /// `transcribing` false shows only what it is told, as the demo does,
    /// until `begin`.
    init(_ options: RecordingOptions = .init(transcribes: true), sides: [Side] = [.room], transcribing: Bool = true) {
        var feeds: [Side: AudioFeed] = [:], streams: [Side: AsyncStream<[Float]>] = [:]
        for side in sides {
            let (stream, continuation) = AsyncStream<[Float]>.makeStream()
            feeds[side] = AudioFeed(continuation)
            streams[side] = stream
        }
        self.feeds = feeds
        self.streams = streams
        self.sides = sides
        self.options = options
        guests = options.guests
        labelsSpeakers = options.labelsSpeakers
        if transcribing { begin() }
    }

    /// Hands the audio to Voz, from the first of it. A recorder calls this
    /// once its capture runs, so a capture that fails to start loads no model.
    func begin() {
        guard let streams else { return }
        self.streams = nil
        let options = options
        result = Task { await self.transcribe(streams, options) }
    }

    var text: String { [committed, tentative].filter { !$0.isEmpty }.joined(separator: " ") }

    /// A run of words by one voice, or by everyone when nobody is told apart.
    struct Paragraph: Identifiable, Equatable {
        let id: Int
        let speaker: Int?
        var settled: [String] = []
        var tentative: [String] = []
    }

    /// The words so far, a paragraph each time the voice changes. The words
    /// Voz may still change are kept apart.
    private(set) var paragraphs: [Paragraph] = []

    /// What one side has heard: the words Voz wrote, the first `settled` of
    /// them settled, and who spoke when on that side, if Who has listened.
    func show(_ side: Side = .room, _ words: [Transcript.Word], settled: Int, turns: [SpeakerTurn]? = nil) {
        var heard = heard[side] ?? Heard()
        heard.words = words
        heard.settled = settled
        if let turns { heard.turns = turns }
        self.heard[side] = heard
        said = Heard.merge(self.heard, voices: labelsSpeakers)
        committed = Self.join(said.filter(\.settled).map(\.word))
        tentative = Self.join(said.filter { !$0.settled }.map(\.word))
        paragraphs = Self.paragraphs(said)
    }

    private static func paragraphs(_ said: [Heard.Said]) -> [Paragraph] {
        var out: [Paragraph] = []
        for said in said {
            let speaker = said.word.speaker
            if out.isEmpty || out[out.count - 1].speaker != speaker { out.append(Paragraph(id: out.count, speaker: speaker)) }
            if said.settled { out[out.count - 1].settled.append(said.word.text) } else { out[out.count - 1].tentative.append(said.word.text) }
        }
        return out
    }

    /// Every voice heard so far, the room's first.
    var voices: [Int] { Set(said.compactMap(\.word.speaker)).sorted() }

    /// The voices in the room, on a call; nil for a recording that is only the microphone.
    var local: Set<Int>? { sides.contains(.call) ? Set(voices.filter { Side.of($0) == .room }) : nil }

    /// What each voice is called now.
    var names: [Int: String] { Speakers.names(voices, local: local, guests: guests, given: given) }

    /// Names a voice; an empty name gives it back the one it had.
    func rename(_ speaker: Int, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        given[speaker] = name.isEmpty ? nil : name
    }

    /// No more audio: Voz settles what it holds, and the whole transcript
    /// comes back.
    func finish() async -> Transcript {
        for feed in feeds.values { feed.finish() }
        return await result?.value ?? Transcript(text: text, words: said.map(\.word))
    }

    private func transcribe(_ streams: [Side: AsyncStream<[Float]>], _ options: RecordingOptions) async -> Transcript {
        do {
            try await ModelHub.shared.prepare(.voz)
            // Without Who the words still come, each with its side's voice.
            let who = options.labelsSpeakers ? (try? await ModelHub.shared.prepare(.who)) != nil : false
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (side, audio) in streams {
                    group.addTask { try await self.listen(side, audio, options, who: who) }
                }
                try await group.waitForAll()
            }
            let words = said.map(\.word)
            var transcript = Transcript(text: Self.join(words), words: words)
            if options.labelsSpeakers {
                transcript.turns = Heard.turns(heard)
                transcript.names = names
            }
            return transcript
        } catch {
            failure = error.localizedDescription
            for audio in streams.values { for await _ in audio {} }
            return Transcript(text: text, words: [])
        }
    }

    /// One side: its audio to its own Voz session and, with `who`, its own
    /// Who, until the audio ends and both have settled.
    private func listen(_ side: Side, _ audio: AsyncStream<[Float]>, _ options: RecordingOptions, who: Bool) async throws {
        let speakers = who ? try? LiveSpeakers() : nil
        do {
            let session = try await ModelHub.voz.live(vocabulary: options.vocabulary)
            let reading = Task { @MainActor [weak self] in
                var last: LiveWords?
                for await update in session.updates {
                    last = update
                    let turns = await speakers?.turns
                    self?.show(side, update.committed + update.tentative, settled: update.committed.count, turns: turns)
                }
                return last
            }
            for await chunk in audio {
                await session.append(chunk, sampleRate: AudioFeed.rate)
                await speakers?.append(chunk)
            }
            await session.finish()
            let words = await reading.value.map { $0.committed + $0.tentative } ?? []
            let turns = await speakers?.finish()
            show(side, words, settled: words.count, turns: turns)
        } catch {
            speakers?.discard()
            throw error
        }
    }

    private nonisolated static func join(_ words: [Transcript.Word]) -> String {
        words.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

/// Turns audio buffers of any format into one channel at the rate Voz reads,
/// and passes them on in the order they came. Called from one capture queue
/// at a time; the lock keeps the converter safe if that ever changes.
final class AudioFeed: @unchecked Sendable {
    static let rate = 16_000.0
    private static let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!

    private let continuation: AsyncStream<[Float]>.Continuation
    private let lock = NSLock()
    private var converter: AVAudioConverter?

    init(_ continuation: AsyncStream<[Float]>.Continuation) {
        self.continuation = continuation
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard buffer.frameLength > 0 else { return }
            if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: Self.format) }
            guard let converter else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.rate / buffer.format.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return }
            nonisolated(unsafe) var given = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if given {
                    status.pointee = .noDataNow
                    return nil
                }
                given = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let data = out.floatChannelData?[0] else { return }
            continuation.yield(Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength))))
        }
    }

    func finish() { continuation.finish() }
}
