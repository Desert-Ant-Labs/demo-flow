import CoreGraphics
import Foundation
import Moderator

final class ModeratorRunner: ModelRunner {
    private let moderator = Moderator()
    private let serial = Serial()

    func isDownloaded() -> Bool { moderator.isDownloaded() }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await moderator.download(progress: progress)
    }

    func analyze(_ image: CGImage, threshold: Double) async throws -> Moderation {
        let moderator = moderator
        return try await serial.run {
            let m = try await moderator.analyze(image, options: .init(threshold: threshold))
            return Moderation(score: m.score, isNSFW: m.isNSFW)
        }
    }
}
