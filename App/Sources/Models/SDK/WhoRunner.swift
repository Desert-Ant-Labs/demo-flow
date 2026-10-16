import Foundation
import Who

final class WhoRunner: ModelRunner {
    private let who = Who()
    private let serial = Serial()

    func isDownloaded() -> Bool { who.isDownloaded() }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await who.download(progress: progress)
    }

    /// Who spoke when, from mono samples at any rate.
    func diarize(_ samples: [Float], sampleRate: Double) async throws -> [SpeakerTurn] {
        let who = who
        return try await serial.run {
            try await who.diarize(samples: samples, sampleRate: sampleRate).turns.map {
                SpeakerTurn(start: $0.start, end: $0.end, speaker: $0.speaker)
            }
        }
    }
}
