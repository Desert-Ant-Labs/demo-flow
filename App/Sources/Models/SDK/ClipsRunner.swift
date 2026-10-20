import Clips
import Foundation
import Transcript

final class ClipsRunner: ModelRunner {
    private let clips = Clips()
    private let serial = Serial()

    func isDownloaded() -> Bool { clips.isDownloaded() }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await clips.download(progress: progress)
    }

    /// The moments worth sharing, best first. Nil count lets the model size it
    /// to the material.
    func moments(in sentences: [Sentence], count: Int?) async throws -> [Moment] {
        let clips = clips
        return try await serial.run {
            try await clips.clips(in: sentences.map(\.text), limit: count).map {
                Moment(text: $0.text, score: $0.score, ranges: $0.ranges(in: sentences))
            }
        }
    }
}
