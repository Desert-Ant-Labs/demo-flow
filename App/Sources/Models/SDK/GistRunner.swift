import Foundation
import Gist

final class GistRunner: ModelRunner {
    private let gist = Gist()
    private let serial = Serial()

    func isDownloaded() -> Bool { gist.isDownloaded() }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await gist.download(progress: progress)
    }

    func classify(_ text: String, topK: Int) async throws -> [Topic] {
        let gist = gist
        return try await serial.run {
            try await gist.classify(text, topK: topK).map { Topic(name: $0.name, score: $0.score) }
        }
    }
}
