import Foundation
import Tongue

/// Tongue's weights come with the app, so there is nothing to download.
final class TongueRunner: ModelRunner, @unchecked Sendable {
    private let serial = Serial()
    private let lock = NSLock()
    private var tongue: Tongue?

    func isDownloaded() -> Bool { true }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try model()
    }

    private func model() throws -> Tongue {
        try lock.withLock {
            if let tongue { return tongue }
            let made = try Tongue()
            tongue = made
            return made
        }
    }

    func detect(_ text: String) async throws -> LanguageGuess {
        let tongue = try model()
        return try await serial.run {
            let d = tongue.detect(text, topK: 3)
            let reliable = !d.isTooCloseToCall && d.reliability != .tentative && d.reliability != .empty
            return LanguageGuess(
                language: d.language ?? "", reliable: reliable,
                candidates: d.candidates.map { .init(language: $0.language, probability: $0.probability) })
        }
    }
}
