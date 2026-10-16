import CoreGraphics
import Foundation
import Shapes

final class ShapesRunner: ModelRunner {
    private let shapes = Shapes()
    private let serial = Serial()

    func isDownloaded() -> Bool { shapes.isDownloaded() }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await shapes.download(progress: progress)
    }

    /// The clean shape a stroke was meant to be, or nil when it is none.
    func recognize(_ points: [CGPoint]) async throws -> CleanShape? {
        let shapes = shapes
        return try await serial.run { () -> CleanShape? in
            guard let shape = try await shapes.recognize(points: points) else { return nil }
            return CleanShape(kind: "\(shape.kind)", points: shape.outline().map(\.cgPoint), closed: shape.isClosed)
        }
    }
}
