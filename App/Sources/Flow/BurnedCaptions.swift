import AVFoundation
import CoreText
import QuartzCore
import Transcript

/// What happens to a clip's captions.
enum CaptionMode: String, Sendable {
    /// Drawn into the picture, which re-encodes the clip.
    case burn
    /// Written beside the clip as an .srt file.
    case srt
    case off
}

/// How burned-in captions look, from a Clips step's settings, as the CLI
/// reads them.
struct CaptionStyle {
    enum Position: String, CaseIterable, Sendable { case bottom, center, top }
    enum Align: String, CaseIterable, Sendable { case left, center, right }
    enum Look: String, CaseIterable, Sendable { case shadow, outline, box }
    enum Quality: String, CaseIterable, Sendable {
        case high, medium, low

        /// The bit rate medium and low write H.264 at. High exports with
        /// Apple's highest preset instead.
        var bitsPerPixel: Double? {
            switch self {
            case .high: nil
            case .medium: 0.05
            case .low: 0.025
            }
        }
    }

    var position = Position.bottom
    var align = Align.center
    /// A font family, or a path to a font file. Nil is Inclusive Sans.
    var font: String?
    /// The text's height as a share of the frame's. Nil sizes it to the frame.
    var size: Double?
    var weight = 700
    var color = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    var look = Look.shadow
    var quality = Quality.high
    /// Lines on screen, 1 or 2. Nil follows the frame's shape.
    var lines: Int?
    /// The most words in one caption. Nil follows the frame's shape.
    var words: Int?

    static let weights = ["regular": 400, "medium": 500, "semibold": 600, "bold": 700, "black": 900]
    static let colors = ["white": "ffffff", "black": "000000", "yellow": "ffdb00", "red": "f03333", "green": "33cc4d",
                         "blue": "3380ff", "cyan": "00d9e6", "magenta": "e633cc"]

    init() {}

    init(_ params: Params) throws {
        func pick<T: RawRepresentable & CaseIterable>(_ key: String) throws -> T? where T.RawValue == String {
            guard let text = params[key]?.string else { return nil }
            guard let value = T(rawValue: text.lowercased()) else {
                throw StepError("\(key.capitalized) is \(T.allCases.map(\.rawValue).formatted(.list(type: .or))), not \(text)")
            }
            return value
        }
        position = try pick("position") ?? position
        align = try pick("align") ?? align
        look = try pick("style") ?? look
        quality = try pick("quality") ?? quality
        if let font = params["font"]?.string, !font.trimmingCharacters(in: .whitespaces).isEmpty { self.font = font }
        if let size = params["size"]?.number {
            guard size > 0, size <= 0.3 else { throw StepError("Size is a share of the frame's height, above 0 and at most 0.3") }
            self.size = size
        }
        if let weight = params["weight"] {
            guard let value = weight.string.flatMap({ Self.weights[$0.lowercased()] }) ?? weight.int, (100...900).contains(value) else {
                throw StepError("Weight is regular, medium, semibold, bold, black, or 100-900")
            }
            self.weight = value
        }
        if let text = params["color"]?.string {
            guard let color = Self.color(text) else { throw StepError("Color is a name such as white or yellow, or a hex color such as #ffcc00") }
            self.color = color
        }
        if let lines = params["lines"]?.int {
            guard lines == 1 || lines == 2 else { throw StepError("Lines is 1 or 2") }
            self.lines = lines
        }
        if let words = params["words"]?.int {
            guard (1...20).contains(words) else { throw StepError("Words is a whole number from 1 to 20") }
            self.words = words
        }
    }

    /// `white`, `#ffcc00`, or `#ffcc0080` with alpha.
    static func color(_ text: String) -> CGColor? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        let hex = colors[t] ?? String(t.trimmingPrefix("#"))
        guard hex.count == 6 || hex.count == 8, let v = UInt32(hex, radix: 16) else { return nil }
        let rgba = hex.count == 6 ? v << 8 | 0xFF : v
        func channel(_ shift: UInt32) -> Double { Double(rgba >> shift & 0xFF) / 255 }
        return CGColor(srgbRed: channel(24), green: channel(16), blue: channel(8), alpha: channel(0))
    }
}

/// How captions are cut for a frame: a few short words on a tall phone video,
/// two lines of a sentence on a wide one.
struct Pacing: Sendable {
    let lines: Int
    let lineLength: Int
    let words: Int?
    /// The longest a caption stays up while the words go on.
    let maxDuration: Double
    /// A pause longer than this starts a new caption.
    let pause: Double
}

/// Where captions go in one frame size: the text's pixel height, the margins,
/// and how the captions are paced.
struct CaptionFrame: Sendable {
    let width: Double
    let height: Double
    /// The height of a line of text, in pixels.
    let lineHeight: Double
    let marginX: Double
    let marginY: Double
    let pacing: Pacing

    init(_ size: CGSize, style: CaptionStyle) {
        width = size.width
        height = size.height
        let aspect = height > 0 ? width / height : 16.0 / 9
        // Sized to the short side, so a portrait clip gets the size a landscape one does.
        lineHeight = ((style.size ?? 0.07 * min(width, height) / height) * height).rounded()
        marginX = (width * 0.06).rounded()
        // Social apps put their buttons over the top and bottom of a tall video.
        marginY = (height * (height > width ? 0.16 : 0.08)).rounded()
        let fit = max(8, Int((width - 2 * marginX) / (lineHeight * 0.5)))
        pacing = switch aspect {
        case ..<0.8: Pacing(lines: style.lines ?? 1, lineLength: min(20, fit), words: style.words ?? 5, maxDuration: 1.5, pause: 0.4)
        case ...1.25: Pacing(lines: style.lines ?? 2, lineLength: min(26, fit), words: style.words, maxDuration: 2.5, pause: 0.7)
        default: Pacing(lines: style.lines ?? 2, lineLength: min(42, fit), words: style.words, maxDuration: 5, pause: 0.7)
        }
    }

    /// The outline, the box's padding, or the shadow's spread, in pixels.
    func border(_ look: CaptionStyle.Look) -> Double {
        switch look {
        case .outline: (lineHeight * 0.075).rounded()
        case .box: (lineHeight * 0.2).rounded()
        case .shadow: (lineHeight * 0.04).rounded()
        }
    }

    /// From one line's top to the next. Boxed lines sit a box apart, so the
    /// boxes touch and never overlap.
    func pitch(_ look: CaptionStyle.Look) -> Double { lineHeight + (look == .box ? 2 * border(.box) : 0) }

    /// The top of the first of `count` lines, from the top of the frame.
    func top(lines count: Int, style: CaptionStyle) -> Double {
        let block = Double(count) * lineHeight + Double(max(count - 1, 0)) * (pitch(style.look) - lineHeight)
        return switch style.position {
        case .bottom: height - marginY - block
        case .top: marginY
        case .center: (height - block) / 2
        }
    }

    var shadowOffset: Double { (lineHeight * 0.03).rounded() }
    var shadowBlur: Double { (lineHeight * 0.16).rounded() }
}

enum ClipCaptions {
    /// Words inside `ranges`, on the clip's own timeline, where the ranges play
    /// end to end. A word belongs to the range its middle falls in.
    static func shift(_ words: [TimedWord], into ranges: [TimeRange]) -> [TimedWord] {
        var out: [TimedWord] = []
        var offset = 0.0
        for range in ranges {
            for word in words where (range.start..<range.end).contains((word.start + word.end) / 2) {
                out.append(TimedWord(text: word.text, start: max(word.start, range.start) - range.start + offset,
                                     end: min(word.end, range.end) - range.start + offset))
            }
            offset += range.duration
        }
        return out
    }

    /// Cues paced for the frame: a new one at the end of a sentence, after a
    /// pause, or once a cue has been up its longest.
    static func social(_ words: [TimedWord], pacing: Pacing) -> [Caption] {
        var cues: [Caption] = []
        var current: [TimedWord] = []
        func text(_ ws: [TimedWord]) -> String {
            pacing.lines == 1 ? Captions.join(ws) : Captions.layout(ws, lineLength: pacing.lineLength)
        }
        func fits(_ ws: [TimedWord]) -> Bool {
            if let limit = pacing.words, ws.count > limit { return false }
            let lines = text(ws).split(separator: "\n")
            return lines.count <= pacing.lines && lines.allSatisfy { $0.count <= pacing.lineLength }
        }
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            cues.append(Caption(start: first.start, end: last.end, text: text(current)))
            current = []
        }
        for word in words {
            if let first = current.first, let last = current.last,
               word.start - last.end > pacing.pause || word.end - first.start > pacing.maxDuration || !fits(current + [word]) {
                flush()
            }
            current.append(word)
            if let end = word.text.trimmingCharacters(in: .whitespaces).last, ".?!".contains(end) { flush() }
        }
        flush()
        return settle(cues)
    }

    /// A cue stays up through a silence under 0.5s, so the screen doesn't
    /// flicker, and clears 0.5s into a longer one. Every cue is up at least
    /// 0.8s, never past the next one's start.
    static func settle(_ cues: [Caption]) -> [Caption] {
        var out: [Caption] = []
        for (i, cue) in cues.enumerated() {
            let start = max(cue.start, out.last?.end ?? 0)
            let next = i + 1 < cues.count ? cues[i + 1].start : .infinity
            let end = min(max(cue.end + min(max(next - cue.end, 0), 0.5), start + 0.8), max(next, start))
            out.append(Caption(start: start, end: max(end, start + 0.01), text: cue.text))
        }
        return out
    }
}

/// Clips with their captions drawn in.
enum Burner {
    /// The ranges end to end, with each cue drawn over the picture, at the
    /// source's size and frame rate.
    static func cut(_ source: URL, ranges: [TimeRange], words: [TimedWord], style: CaptionStyle, to destination: URL) async throws {
        let composition = try await Cutter.composition(of: AVURLAsset(url: source), keeping: ranges)
        var configuration = try await AVVideoComposition.Configuration(for: composition)
        let frame = CaptionFrame(configuration.renderSize, style: style)
        let renderer = try CaptionRenderer(frame: frame, style: style)
        let drawn = ClipCaptions.social(words, pacing: frame.pacing).compactMap(renderer.draw)
        let type: AVFileType = destination.pathExtension.lowercased() == "mov" ? .mov : .mp4
        if let bitsPerPixel = style.quality.bitsPerPixel {
            try await CaptionWriter.write(composition, AVVideoComposition(configuration: configuration), drawn,
                                          bitsPerPixel: bitsPerPixel, as: type, to: destination)
        } else {
            configuration.animationTool = layers(drawn, size: configuration.renderSize)
            try await Cutter.export(composition, preset: AVAssetExportPresetHighestQuality, as: type,
                                    videoComposition: AVVideoComposition(configuration: configuration), to: destination)
        }
    }

    /// Each cue as a layer that shows for the cue's time, over the picture.
    private static func layers(_ drawn: [DrawnCue], size: CGSize) -> AVVideoCompositionCoreAnimationTool {
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        let picture = CALayer()
        picture.frame = parent.frame
        parent.addSublayer(picture)
        for cue in drawn {
            let layer = CALayer()
            layer.contents = cue.image
            layer.frame = cue.rect
            layer.opacity = 0
            let show = CABasicAnimation(keyPath: "opacity")
            show.fromValue = 1
            show.toValue = 1
            show.beginTime = cue.start <= 0 ? AVCoreAnimationBeginTimeAtZero : cue.start
            show.duration = cue.end - cue.start
            show.isRemovedOnCompletion = false
            layer.add(show, forKey: "show")
            parent.addSublayer(layer)
        }
        return AVVideoCompositionCoreAnimationTool(configuration: .init(postProcessingAsVideoLayer: picture, containingLayer: parent))
    }
}

/// A cue drawn once, and where it goes, bottom-left origin as video frames
/// have it.
struct DrawnCue: Sendable {
    let start: Double
    let end: Double
    let image: CGImage
    let rect: CGRect
}

/// Draws a cue's lines inside the frame's margins, with a shadow, an
/// outline, or a box behind them.
struct CaptionRenderer {
    private let font: CTFont
    private let baseline: Double
    private let frame: CaptionFrame
    private let style: CaptionStyle

    init(frame: CaptionFrame, style: CaptionStyle) throws {
        let descriptor = try Self.descriptor(style.font, weight: style.weight)
        let (ascent, descent) = Self.lineMetrics(CTFontCreateWithFontDescriptor(descriptor, 1, nil))
        font = CTFontCreateWithFontDescriptor(descriptor, frame.lineHeight / (ascent + descent), nil)
        baseline = frame.lineHeight * ascent / (ascent + descent)
        self.frame = frame
        self.style = style
    }

    /// The font's Windows ascent and descent per point. libass fills a line
    /// with them, and so does the CLI, so a caption is the same size in both.
    private static func lineMetrics(_ font: CTFont) -> (ascent: Double, descent: Double) {
        guard let os2 = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?, os2.count >= 78 else {
            return (CTFontGetAscent(font), CTFontGetDescent(font))
        }
        let em = Double(CTFontGetUnitsPerEm(font))
        let read = { (at: Int) in Double(UInt16(os2[at]) << 8 | UInt16(os2[at + 1])) / em }
        return (read(74), read(76))
    }

    /// Inclusive Sans, a font file, or a family on this Mac.
    private static func descriptor(_ name: String?, weight: Int) throws -> CTFontDescriptor {
        guard let name, name.caseInsensitiveCompare("Inclusive Sans") != .orderedSame else {
            let file = weight >= 600 ? "InclusiveSans-Bold" : "InclusiveSans-Regular"
            return try face(Bundle.main.url(forResource: file, withExtension: "ttf", subdirectory: "Fonts")!)
        }
        if name.contains("/") { return try face(URL(filePath: (name as NSString).expandingTildeInPath)) }
        let trait = switch weight {
        case ..<200: -0.8
        case ..<300: -0.6
        case ..<400: -0.4
        case ..<500: 0.0
        case ..<600: 0.23
        case ..<700: 0.3
        case ..<800: 0.4
        case ..<900: 0.56
        default: 0.62
        }
        let wanted = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: name, kCTFontTraitsAttribute: [kCTFontWeightTrait: trait],
        ] as CFDictionary)
        guard let match = CTFontDescriptorCreateMatchingFontDescriptor(wanted, [kCTFontFamilyNameAttribute] as NSSet) else {
            throw StepError("There's no font named \(name) on this Mac")
        }
        return match
    }

    private static func face(_ file: URL) throws -> CTFontDescriptor {
        guard let face = (CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor])?.first else {
            throw StepError("\(file.lastPathComponent) isn't a font")
        }
        return face
    }

    private struct Line {
        let path: CGPath
        let x: Double
        let top: Double
        let width: Double
    }

    private func lines(_ text: String) -> [Line] {
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let top = frame.top(lines: rows.count, style: style), pitch = frame.pitch(style.look)
        return rows.enumerated().map { i, row in
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: row, attributes: [.init(kCTFontAttributeName as String): font]))
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            let path = CGMutablePath()
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let count = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(), &glyphs)
                CTRunGetPositions(run, CFRange(), &positions)
                let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
                for (glyph, at) in zip(glyphs, positions) {
                    if let outline = CTFontCreatePathForGlyph(runFont, glyph, nil) {
                        path.addPath(outline, transform: CGAffineTransform(translationX: at.x, y: at.y))
                    }
                }
            }
            let x = switch style.align {
            case .left: frame.marginX
            case .center: (frame.width - width) / 2
            case .right: frame.width - frame.marginX - width
            }
            return Line(path: path, x: x, top: Double(i) * pitch + top, width: width)
        }
    }

    /// The cue drawn the size of what it draws, and where that goes.
    func draw(_ cue: Caption) -> DrawnCue? {
        let lines = lines(cue.text)
        guard let first = lines.first, let last = lines.last else { return nil }
        let border = frame.border(style.look)
        let reach = style.look == .shadow ? border + 2 * frame.shadowBlur : border + 1
        let drop = style.look == .shadow ? frame.shadowOffset : 0
        let minX = lines.map(\.x).min()! - reach, maxX = lines.map { $0.x + $0.width }.max()! + reach
        let minY = first.top - reach, maxY = last.top + frame.lineHeight + reach + drop
        let box = CGRect(x: floor(minX), y: floor(minY), width: ceil(maxX - minX) + 1, height: ceil(maxY - minY) + 1)
        guard let context = CGContext(data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        func placed(_ line: Line, dx: Double = 0) -> CGPath? {
            var t = CGAffineTransform(translationX: line.x - box.minX + dx, y: box.maxY - (line.top + baseline))
            return line.path.copy(using: &t)
        }
        func addOutline(_ path: CGPath) {
            context.addPath(path)
            context.setLineWidth(2 * border)
            context.setLineJoin(.round)
            context.setStrokeColor(black)
            context.setFillColor(black)
        }
        switch style.look {
        case .box:
            // One fill for every line's box, so the shade stays even where they meet.
            context.addRects(lines.map {
                CGRect(x: $0.x - border - box.minX, y: box.maxY - $0.top - frame.lineHeight - border,
                       width: $0.width + 2 * border, height: frame.lineHeight + 2 * border)
            })
            context.setFillColor(black.copy(alpha: 0.7)!)
            context.fillPath(using: .winding)
        case .shadow:
            // The text drawn off the canvas casts its blurred shadow back onto it.
            let away = box.width + 4 * reach
            for line in lines {
                guard let path = placed(line, dx: away) else { continue }
                context.saveGState()
                context.setShadow(offset: CGSize(width: -away, height: -frame.shadowOffset), blur: frame.shadowBlur, color: black.copy(alpha: 0.55))
                addOutline(path)
                context.drawPath(using: .fillStroke)
                context.restoreGState()
            }
        case .outline:
            for line in lines {
                guard let path = placed(line) else { continue }
                addOutline(path)
                context.strokePath()
            }
        }
        for line in lines {
            guard let path = placed(line) else { continue }
            context.addPath(path)
            context.setFillColor(style.color)
            context.fillPath()
        }
        guard let image = context.makeImage() else { return nil }
        return DrawnCue(start: cue.start, end: cue.end, image: image,
                        rect: CGRect(x: box.minX, y: frame.height - box.maxY, width: box.width, height: box.height))
    }
}

/// Reads the composed frames, draws the cue that is showing into each, and
/// writes them as H.264 at a bit rate set by `bitsPerPixel`, with the sound
/// as AAC. Apple's presets below the highest shrink the picture, so the
/// smaller files are written here instead.
enum CaptionWriter {
    static func write(_ composition: AVComposition, _ video: AVVideoComposition, _ drawn: [DrawnCue],
                      bitsPerPixel: Double, as type: AVFileType, to destination: URL) async throws {
        let videoTracks = try await composition.loadTracks(withMediaType: .video)
        let audioTracks = try await composition.loadTracks(withMediaType: .audio)
        let size = video.renderSize
        let frameRate = video.frameDuration.seconds > 0 ? 1 / video.frameDuration.seconds : 30
        try? FileManager.default.removeItem(at: destination)

        let reader = try AVAssetReader(asset: composition)
        let pictureOut = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks,
                                                             videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        pictureOut.videoComposition = video
        let writer = try AVAssetWriter(outputURL: destination, fileType: type)
        let pictureIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(bitsPerPixel * size.width * size.height * frameRate),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        pictureIn.expectsMediaDataInRealTime = false
        let format = CVPixelBufferCreationAttributes(pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA), size: CVImageSize(size))
        let frames = writer.inputPixelBufferReceiver(for: pictureIn, pixelBufferAttributes: format)
        let pictures = reader.outputProvider(for: pictureOut)

        var sound: (from: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>, to: AVAssetWriterInput.SampleBufferReceiver)?
        if !audioTracks.isEmpty {
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
            ])
            input.expectsMediaDataInRealTime = false
            sound = (reader.outputProvider(for: out), writer.inputReceiver(for: input))
        }

        try reader.start()
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        let pool = try CVMutablePixelBuffer.Pool(pixelBufferAttributes: format)
        async let picturesDone: Void = {
            while let sample = try await pictures.next() {
                guard case .pixelBuffer(let frame) = sample.content else { continue }
                let time = sample.presentationTimeStamp
                let showing = drawn.filter { ($0.start..<$0.end).contains(time.seconds) }
                guard !showing.isEmpty else {
                    try await frames.append(frame, with: time)
                    continue
                }
                let captioned = try pool.makeMutablePixelBuffer()
                frame.withUnsafeBuffer { source in captioned.withUnsafeBuffer { draw(showing, over: source, into: $0) } }
                try await frames.append(CVReadOnlyPixelBuffer(captioned), with: time)
            }
            frames.finish()
        }()
        async let soundDone: Void = {
            guard let sound else { return }
            while let sample = try await sound.from.next() { try await sound.to.append(sample) }
            sound.to.finish()
        }()
        _ = try await (picturesDone, soundDone)
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? StepError("The clip couldn't be written") }
    }

    /// The frame copied into `target`, with the cues drawn over it.
    private static func draw(_ cues: [DrawnCue], over frame: CVPixelBuffer, into target: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        CVPixelBufferLockBaseAddress(target, [])
        defer {
            CVPixelBufferUnlockBaseAddress(target, [])
            CVPixelBufferUnlockBaseAddress(frame, .readOnly)
        }
        guard let from = CVPixelBufferGetBaseAddress(frame), let to = CVPixelBufferGetBaseAddress(target) else { return }
        let rows = min(CVPixelBufferGetHeight(frame), CVPixelBufferGetHeight(target))
        let fromStride = CVPixelBufferGetBytesPerRow(frame), toStride = CVPixelBufferGetBytesPerRow(target)
        for row in 0..<rows {
            (to + row * toStride).copyMemory(from: from + row * fromStride, byteCount: min(fromStride, toStride))
        }
        guard let context = CGContext(data: to, width: CVPixelBufferGetWidth(target), height: CVPixelBufferGetHeight(target),
                                      bitsPerComponent: 8, bytesPerRow: toStride, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        for cue in cues { context.draw(cue.image, in: cue.rect) }
    }
}
