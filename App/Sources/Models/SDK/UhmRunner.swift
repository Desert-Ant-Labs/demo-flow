import Foundation
import Uhm

final class UhmRunner: ModelRunner {
    private let uhm = Uhm()
    private let serial = Serial()

    func isDownloaded() -> Bool { uhm.isDownloaded() }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await uhm.download(progress: progress)
    }

    /// The uh, um, and hmm in 16 kHz mono.
    func fillers(_ samples: [Float]) async throws -> [Filler] {
        let uhm = uhm
        return try await serial.run {
            try await uhm.analyze(samples: samples, sampleRate: 16_000).fillers.map {
                Filler(type: $0.type?.rawValue ?? "filler", start: $0.start, end: $0.end, confidence: $0.confidence)
            }
        }
    }
}
