import Ear
import Foundation

final class EarRunner: ModelRunner {
    private let ear = Ear()
    private let serial = Serial()

    func isDownloaded() -> Bool { Ear.isDownloaded() }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await ear.download(progress: progress)
    }

    func identify(_ samples: [Float], sampleRate: Double) async throws -> LanguageGuess {
        let ear = ear
        return try await serial.run {
            let d = try await ear.identify(samples: samples, sampleRate: sampleRate)
            return LanguageGuess(
                language: d.language ?? "", reliable: d.isReliable,
                candidates: d.candidates.map { .init(language: $0.language, probability: $0.probability) })
        }
    }
}
