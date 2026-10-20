import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reading recordings and photos, and writing them back out.
enum Media {
    /// The long side of a photo's working copy, the size of the samples.
    static let workSide = 1600
    static let thumbSide = 480

    // MARK: Audio

    /// Any recording or video, as mono samples at `sampleRate`.
    static func audio(_ url: URL, sampleRate: Double = 48_000, name: String? = nil) async throws -> AudioClip {
        let label = name ?? url.deletingPathExtension().lastPathComponent
        // AVAudioFile reads wav, aiff, caf, m4a, mp3, and flac directly. A video,
        // or anything it does not take, goes through AVAssetReader.
        let samples = if let file = try? AVAudioFile(forReading: url) {
            try readFile(file, sampleRate: sampleRate)
        } else {
            try await readAsset(url, sampleRate: sampleRate)
        }
        return AudioClip(samples: samples, sampleRate: sampleRate, name: label, file: url)
    }

    private static func monoFormat(_ rate: Double) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    }

    private static func readFile(_ file: AVAudioFile, sampleRate: Double) throws -> [Float] {
        let input = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: frames) else {
            throw StepError("That recording is empty")
        }
        try file.read(into: buffer)
        return try convert(buffer, to: sampleRate)
    }

    private static func readAsset(_ url: URL, sampleRate: Double) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw StepError("That file has no sound in it")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        reader.startReading()
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            guard length >= 4 else { continue }
            var chunk = [Float](repeating: 0, count: length / 4)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            samples += chunk
        }
        if reader.status == .failed { throw reader.error ?? StepError("That file could not be read") }
        guard !samples.isEmpty else { throw StepError("That recording is empty") }
        return samples
    }

    /// Mixes down to mono and changes the rate in one pass.
    private static func convert(_ buffer: AVAudioPCMBuffer, to rate: Double) throws -> [Float] {
        let target = monoFormat(rate)
        if buffer.format.channelCount == 1, buffer.format.sampleRate == rate, buffer.format.commonFormat == .pcmFormatFloat32 {
            return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        guard let converter = AVAudioConverter(from: buffer.format, to: target) else {
            throw StepError("That recording could not be converted")
        }
        if buffer.format.channelCount > 1 {
            converter.channelMap = [0]
            converter.downmix = true
        }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * rate / buffer.format.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw StepError("That recording is too long")
        }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }

    /// The same sound at another rate. The models each want their own.
    static func resample(_ clip: AudioClip, to rate: Double) throws -> [Float] {
        if clip.sampleRate == rate { return clip.samples }
        let format = monoFormat(clip.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(clip.samples.count)) else {
            throw StepError("That recording is too long")
        }
        buffer.frameLength = AVAudioFrameCount(clip.samples.count)
        clip.samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: clip.samples.count) }
        return try convert(buffer, to: rate)
    }

    /// 16-bit PCM WAV, which every app opens.
    static func wav(_ clip: AudioClip) -> Data {
        let count = clip.samples.count
        var data = Data(capacity: 44 + count * 2)
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let rate = UInt32(clip.sampleRate)
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(rate); put(rate * 2); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(UInt32(count * 2))
        var pcm = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let s = max(-1, min(1, clip.samples[i]))
            pcm[i] = Int16(s < 0 ? s * 32768 : s * 32767)
        }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    // MARK: Photos

    /// When a photo was taken, from its EXIF, in seconds since 1970.
    static func captureDate(_ url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let exif = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let stamp = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }
        let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = offset == nil ? "yyyy:MM:dd HH:mm:ss" : "yyyy:MM:dd HH:mm:ssXXXXX"
        return format.date(from: stamp + (offset ?? ""))?.timeIntervalSince1970
    }

    /// A photo file, at the working size and as a thumbnail.
    static func photo(_ url: URL) throws -> Photo {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw StepError("That file is not a photo")
        }
        guard let image = scaled(source, side: workSide), let thumb = scaled(source, side: thumbSide) else {
            throw StepError("That photo could not be read")
        }
        return Photo(image: image, thumb: thumb, name: url.lastPathComponent, file: url)
    }

    /// A drawing made in the app, as a photo.
    static func photo(_ image: CGImage, name: String) -> Photo {
        let k = min(1, Double(thumbSide) / Double(max(image.width, image.height)))
        return Photo(image: image, thumb: resized(image, k) ?? image, name: name, file: nil)
    }

    /// Decoded straight to size and turned upright, which is what ImageIO's
    /// thumbnail does when asked for the whole picture.
    private static func scaled(_ source: CGImageSource, side: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    private static func resized(_ image: CGImage, _ k: Double) -> CGImage? {
        let w = max(1, Int(Double(image.width) * k)), h = max(1, Int(Double(image.height) * k))
        guard let ctx = canvas(width: w, height: h) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func png(_ image: CGImage) -> Data {
        let data = NSMutableData()
        if let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
        return data as Data
    }

    /// An empty sRGB bitmap to draw into.
    private static func canvas(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    // MARK: Drawings

    /// Strokes and shapes as one picture, framed to what was drawn, dark on
    /// cream like ink on paper, so other steps can take it like any photo.
    static func drawing(strokes: [[CGPoint]] = [], shapes: [CleanShape] = []) -> Photo? {
        let outlines = strokes.map { ($0, false) } + shapes.map { ($0.points, $0.closed) }
        let all = outlines.flatMap(\.0)
        guard all.count >= 2 else { return nil }
        let x0 = all.map(\.x).min()!, y0 = all.map(\.y).min()!
        let x1 = all.map(\.x).max()!, y1 = all.map(\.y).max()!
        let span = max(x1 - x0, y1 - y0, 1), pad = span * 0.12
        let box = CGRect(x: x0 - pad, y: y0 - pad, width: x1 - x0 + pad * 2, height: y1 - y0 + pad * 2)
        let side = 640.0
        let k = side / max(box.width, box.height)
        let w = Int((box.width * k).rounded()), h = Int((box.height * k).rounded())
        guard let ctx = canvas(width: w, height: h) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0.984, green: 0.980, blue: 0.957, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: k, y: -k)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.setStrokeColor(CGColor(srgbRed: 0.055, green: 0.067, blue: 0.075, alpha: 1))
        ctx.setLineWidth(span / 90)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for (points, closed) in outlines where points.count > 1 {
            ctx.addLines(between: points)
            if closed { ctx.closePath() }
            ctx.strokePath()
        }
        guard let image = ctx.makeImage() else { return nil }
        return photo(image, name: "drawing.png")
    }
}

/// Decoded recordings and photos, kept while the app runs so they are decoded
/// only once. Past a limit, the ones used longest ago are let go.
actor MediaCache {
    static let shared = MediaCache()

    private var audio = Recent<AudioClip>()
    private var photos = Recent<Photo>()

    func audio(_ url: URL) async throws -> AudioClip {
        if let task = audio.get(url) { return try await task.value }
        let task = Task.detached(priority: .userInitiated) { try await Media.audio(url, name: Samples.label(for: url)) }
        audio.put(url, task, limit: 12)
        do { return try await task.value } catch {
            audio.remove(url)
            throw error
        }
    }

    func photo(_ url: URL) async throws -> Photo {
        if let task = photos.get(url) { return try await task.value }
        let task = Task.detached(priority: .userInitiated) { try Media.photo(url) }
        photos.put(url, task, limit: 300)
        do { return try await task.value } catch {
            photos.remove(url)
            throw error
        }
    }

    private struct Recent<T: Sendable> {
        private var tasks: [URL: Task<T, Error>] = [:]
        private var order: [URL] = []

        mutating func get(_ url: URL) -> Task<T, Error>? {
            guard let task = tasks[url] else { return nil }
            order.removeAll { $0 == url }
            order.append(url)
            return task
        }

        mutating func put(_ url: URL, _ task: Task<T, Error>, limit: Int) {
            tasks[url] = task
            order.removeAll { $0 == url }
            order.append(url)
            while order.count > limit { tasks[order.removeFirst()] = nil }
        }

        mutating func remove(_ url: URL) {
            tasks[url] = nil
            order.removeAll { $0 == url }
        }
    }
}
