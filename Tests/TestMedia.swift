import AVFoundation
import Foundation
@testable import Flow

/// A video of plain gray frames, silent or with `sound` as its audio.
func grayVideo(_ size: CGSize, seconds: Double, sound: URL? = nil) async throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appending(path: "gray.mp4")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
    ])
    let format = CVPixelBufferCreationAttributes(pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA), size: CVImageSize(size))
    let frames = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: format)
    try writer.start()
    writer.startSession(atSourceTime: .zero)
    let pool = try CVMutablePixelBuffer.Pool(pixelBufferAttributes: format)
    for i in 0..<Int(seconds * 30) {
        let frame = try pool.makeMutablePixelBuffer()
        frame.withUnsafeBuffer { buffer in
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 0x4C, CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
        }
        try await frames.append(CVReadOnlyPixelBuffer(frame), with: CMTime(value: CMTimeValue(i), timescale: 30))
    }
    frames.finish()
    await writer.finishWriting()
    guard let sound else { return url }
    let talking = folder.appending(path: "talking.mp4")
    return try await Cutter.replaceAudio(of: url, with: sound, to: talking)
}

/// How many pixels in `rows` are near white.
func brightPixels(_ image: CGImage, rows: Range<Int>) -> Int {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return rows.clamped(to: 0..<height).reduce(0) { count, y in
        count + (0..<width).filter { x in pixels[(y * width + x) * 4..<(y * width + x) * 4 + 3].allSatisfy { $0 > 220 } }.count
    }
}
