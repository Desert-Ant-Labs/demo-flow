import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Read text: the words in a photo, a scan, or a screenshot.
///
/// This step is not one of our models. It runs Apple's Vision text
/// recognition (`VNRecognizeTextRequest`), which ships with macOS and runs on
/// this Mac like everything else in a flow: nothing is downloaded and nothing
/// leaves it. It is here so the text models have something to read in a
/// photo: Redact on a receipt, Tongue on a street sign, Gist on a screenshot.
enum ReadTextStep {
    static let def = StepDef(
        type: "readtext", title: "Read text", description: "Text in a photo, scan, or screenshot, read with Apple's Vision on this Mac",
        category: .logic,
        inputs: [Port(id: "image", type: .image, label: "Photo")],
        outputs: [Port(id: "text", type: .text, label: "Text"), Port(id: "lines", type: .text, label: "Lines", each: "line")],
        defaults: ["fast": false]
    ) { run in
        guard let photo = run.inputs["image"]?.photo else { throw StepError("No photo") }
        let lines = try await read(photo, fast: run.params["fast"]?.bool ?? false)
        return ["text": .text(lines.joined(separator: "\n")), "lines": .list(lines.map { .text($0) })]
    }

    /// The lines of text in a photo, top to bottom. Reads the original file at
    /// full size when there is one, since small print needs every pixel.
    static func read(_ photo: Photo, fast: Bool) async throws -> [String] {
        let image = photo.file.flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } ?? photo.image
        let orientation = photo.file.flatMap(exifOrientation) ?? .up
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = fast ? .fast : .accurate
                    request.usesLanguageCorrection = !fast
                    request.automaticallyDetectsLanguage = true
                    try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
                    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                })
            }
        }
    }

    /// How the camera held the photo, so Vision reads it upright.
    private static func exifOrientation(_ url: URL) -> CGImagePropertyOrientation? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let raw = (props[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value
        else { return nil }
        return CGImagePropertyOrientation(rawValue: raw)
    }
}
