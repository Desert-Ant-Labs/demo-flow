import Foundation
import Toxic

final class ToxicRunner: ModelRunner {
    private let toxic = Toxic()
    private let serial = Serial()

    func isDownloaded() -> Bool { toxic.isDownloaded() }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await toxic.download(progress: progress)
    }

    func analyze(_ text: String) async throws -> Toxicity {
        let toxic = toxic
        return try await serial.run {
            let a = try await toxic.analyze(text)
            return Toxicity(isToxic: a.isToxic, score: Label.content.map(a.score).max() ?? 0,
                            content: a.content.map(Self.name), targets: a.targets.map(Self.name))
        }
    }

    private static func name(_ label: Label) -> String {
        switch label {
        case .nationalOrEthnicOrigin: "national or ethnic origin"
        case .sexualOrientation: "sexual orientation"
        default: label.rawValue.lowercased()
        }
    }
}
