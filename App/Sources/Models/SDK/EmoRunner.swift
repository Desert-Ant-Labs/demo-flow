import Emo
import Foundation

final class EmoRunner: ModelRunner {
    private let emo = Emo()
    private let serial = Serial()

    func isDownloaded() -> Bool { emo.isDownloaded() }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await emo.download(progress: progress)
    }

    func suggestions(_ text: String, limit: Int) async throws -> [Suggestion] {
        let emo = emo
        return try await serial.run {
            try await emo.suggestions(for: text, limit: limit).map { Suggestion(emoji: $0.emoji, confidence: $0.confidence) }
        }
    }
}
