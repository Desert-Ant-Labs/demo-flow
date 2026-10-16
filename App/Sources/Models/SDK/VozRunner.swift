import Foundation
import Voz

/// Voz, made once and loaded on first use.
final class VozRunner: ModelRunner, @unchecked Sendable {
    private let serial = Serial()
    private let lock = NSLock()
    private var loading: Task<Voz, Error>?

    func isDownloaded() -> Bool { Voz.isDownloaded() }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await model(progress: progress)
    }

    private func model(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Voz {
        let task = lock.withLock {
            if let loading { return loading }
            let task = Task { try await Voz { progress($0.fraction) } }
            loading = task
            return task
        }
        do { return try await task.value } catch {
            lock.withLock { if loading == task { loading = nil } }
            throw error
        }
    }

    /// Mono samples at any rate.
    func transcribe(_ samples: [Float], sampleRate: Double) async throws -> Transcript {
        let voz = try await model()
        return try await serial.run {
            let result = try await voz.transcribe(samples: samples, sampleRate: sampleRate)
            return Transcript(
                text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                words: result.words.map { Transcript.Word(text: $0.text, start: $0.start, end: $0.end) })
        }
    }
}

extension VozRunner {
    /// A live session: audio goes in as it is heard, and the words come back
    /// within about a second, settled and still changing.
    /// `vocabulary` names words the audio likely holds, as they should be
    /// written: the people on a call.
    func live(vocabulary: [String] = []) async throws -> LiveSession {
        LiveSession(try await model(), vocabulary: vocabulary)
    }
}

/// What a live session has heard so far.
struct LiveWords: Sendable {
    let committed: [Transcript.Word]
    let tentative: [Transcript.Word]
    let isFinal: Bool
}

/// Voz's live transcriber, in Flow's own types.
///
/// The transcriber settles its last words on a pass that may have started
/// before the last audio came in, and drops that audio. So the session keeps
/// the last stretch of audio itself, and on the final update transcribes
/// whatever came after the last settled word.
actor LiveSession {
    nonisolated let updates: AsyncStream<LiveWords>
    private let output: AsyncStream<LiveWords>.Continuation
    private let voz: Voz
    private let transcriber: LiveTranscriber
    private let vocabulary: [String]
    private var tail: [Float] = []
    private var tailStart = 0.0
    private var heard = 0.0
    private var rate = 16_000.0
    private static let kept = 30.0

    fileprivate init(_ voz: Voz, vocabulary: [String]) {
        self.voz = voz
        self.vocabulary = vocabulary
        var configuration = Voz.LiveConfiguration()
        configuration.vocabulary = vocabulary
        transcriber = voz.liveTranscriber(configuration: configuration)
        (updates, output) = AsyncStream.makeStream()
        Task { await self.forward() }
    }

    func append(_ samples: [Float], sampleRate: Double) async {
        rate = sampleRate
        tail.append(contentsOf: samples)
        heard += Double(samples.count) / sampleRate
        let over = tail.count - Int(Self.kept * sampleRate)
        if over > Int(sampleRate * 5) {
            tail = Array(tail[over...])
            tailStart += Double(over) / sampleRate
        }
        await transcriber.append(samples, sampleRate: sampleRate)
    }

    func finish() async { await transcriber.finish() }

    private func forward() async {
        for await update in transcriber.updates {
            let words = LiveWords(committed: update.committedWords.map(Self.word), tentative: update.tentativeWords.map(Self.word), isFinal: update.isFinal)
            output.yield(update.isFinal ? await mended(words) : words)
        }
        output.finish()
    }

    /// The final words, with whatever came after the last settled word.
    private func mended(_ final: LiveWords) async -> LiveWords {
        let from = max(final.committed.last?.end ?? 0, tailStart)
        let start = Int((from - tailStart) * rate)
        guard heard - from > 0.3, start < tail.count,
              let result = try? await voz.transcribe(samples: Array(tail[start...]), sampleRate: rate, vocabulary: vocabulary)
        else { return final }
        let missing = result.words.map { Transcript.Word(text: $0.text, start: $0.start + from, end: $0.end + from) }
        return LiveWords(committed: final.committed + missing, tentative: [], isFinal: true)
    }

    private static func word(_ w: Word) -> Transcript.Word {
        Transcript.Word(text: w.text, start: w.start, end: w.end)
    }
}
