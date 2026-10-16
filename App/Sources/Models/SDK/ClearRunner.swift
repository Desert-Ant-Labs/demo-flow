import Clear
import Foundation

final class ClearRunner: ModelRunner {
    private let clear = Clear()
    private let serial = Serial()

    func isDownloaded() -> Bool { Clear.isDownloaded() }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await clear.download(progress: progress)
    }

    /// Takes 48 kHz mono and gives it back cleaned, at the loudness asked for:
    /// podcast, spotify, youtube, broadcast, or off.
    func enhance(_ samples: [Float], loudness: String) async throws -> (samples: [Float], sampleRate: Double) {
        let mastering: Clear.Mastering = switch loudness {
        case "spotify": .spotify
        case "youtube": .youtube
        case "broadcast": .broadcast
        case "off": .bypass
        default: .applePodcasts
        }
        let clear = clear
        return try await serial.run {
            let result = try await clear.enhance(samples: samples, sampleRate: 48_000, options: .init(mastering: mastering))
            return (result.samples, result.sampleRate)
        }
    }
}
