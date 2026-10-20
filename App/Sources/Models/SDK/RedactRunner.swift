import Foundation
import Redact

final class RedactRunner: ModelRunner {
    private let redact = Redact()
    private let serial = Serial()

    func isDownloaded() -> Bool { redact.isDownloaded() }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await redact.download(progress: progress)
    }

    func find(in text: String, confidence: Double) async throws -> Redacted {
        let redact = redact
        return try await serial.run {
            let r = try await redact.redaction(of: text, options: Options(minimumConfidence: confidence))
            return Redacted(items: r.items.map {
                .init(label: $0.label.rawValue, original: $0.original, confidence: $0.confidence, range: $0.range)
            })
        }
    }
}
