import CoreGraphics
import Face
import Foundation

final class FaceRunner: ModelRunner {
    private let face = Face()
    private let serial = Serial()

    func isDownloaded() -> Bool { face.isDownloaded() }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await face.download(progress: progress)
    }

    /// Everyone in at least two photos, as photo indices, most photographed first.
    func people(in images: [CGImage], progress: (Int) -> Void) async throws -> [[Int]] {
        let face = face
        var library = FaceLibrary()
        for (i, image) in images.enumerated() {
            progress(i)
            library.add(try await serial.run { try await face.faces(in: image) }, photo: String(i))
        }
        library.regroup()
        return library.people().map { person in
            Array(Set(person.faces.compactMap { library.face($0).flatMap { Int($0.photo) } })).sorted()
        }
    }
}
