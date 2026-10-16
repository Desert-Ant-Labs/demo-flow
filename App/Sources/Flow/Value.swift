import CoreGraphics
import Foundation

/// Mono audio at its own rate, as it moves between steps.
final class AudioClip: @unchecked Sendable {
    let samples: [Float]
    let sampleRate: Double
    let name: String

    init(samples: [Float], sampleRate: Double, name: String) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.name = name
    }

    var duration: Double { Double(samples.count) / sampleRate }
}

/// A photo as it moves between steps: a working copy at most 1600 pixels on
/// its long side for the models and the large views, a small one for cards,
/// and the file it came from for saving and sharing.
final class Photo: @unchecked Sendable, Identifiable {
    let image: CGImage
    let thumb: CGImage
    let name: String
    /// The original file, when there is one. A drawing has none.
    let file: URL?

    init(image: CGImage, thumb: CGImage, name: String, file: URL?) {
        self.image = image
        self.thumb = thumb
        self.name = name
        self.file = file
    }

    var width: Int { image.width }
    var height: Int { image.height }
}

/// A pen stroke, in the coordinates of the board it was drawn on.
struct Stroke: Hashable, Sendable {
    var points: [CGPoint]
}

/// A clean shape from Shapes, in the coordinates of the stroke it came from.
struct CleanShape: Hashable, Sendable {
    var kind: String
    var points: [CGPoint]
    var closed: Bool
}

/// Everything that moves along a wire.
///
/// A `stream` is a loop's items in flight: an output set to go on one item at a time starts one, and every
/// step after it runs once per item until a step that takes the whole list
/// collects it. A nil item is one a branch skipped, kept so lists stay aligned.
/// A `list` is one value that happens to hold several.
indirect enum Value: @unchecked Sendable {
    case text(String)
    case number(Double)
    case bool(Bool)
    case audio(AudioClip)
    case image(Photo)
    /// Any other file, for the steps that rename, copy, and move files.
    case file(URL)
    case stroke(Stroke)
    case shape(CleanShape)
    case list([Value?])
    case stream([Value?])
    case record([(String, Value)])

    var isStream: Bool {
        if case .stream = self { true } else { false }
    }

    /// The items of a list or a stream, holes included. Anything else is a
    /// list of one.
    var items: [Value?] {
        switch self {
        case .list(let l), .stream(let l): l
        default: [self]
        }
    }

    var present: [Value] { items.compactMap { $0 } }

    var string: String? {
        if case .text(let s) = self { s } else { nil }
    }

    var photo: Photo? {
        if case .image(let p) = self { p } else { nil }
    }

    /// The file a value came from: a file, or a photo opened from one.
    var fileURL: URL? {
        switch self {
        case .file(let url): url
        case .image(let p): p.file
        default: nil
        }
    }

    var audio: AudioClip? {
        if case .audio(let a) = self { a } else { nil }
    }

    subscript(key: String) -> Value? {
        if case .record(let fields) = self { fields.first { $0.0 == key }?.1 } else { nil }
    }

    /// The value as words: for templates, comparisons, and copying.
    var asText: String {
        switch self {
        case .text(let s): return s
        case .number(let n): return Value.format(n)
        case .bool(let b): return b ? "true" : "false"
        case .audio(let a): return a.name
        case .image(let p): return p.name
        case .file(let url): return url.lastPathComponent
        case .stroke: return "stroke"
        case .shape(let s): return s.kind
        case .list(let l), .stream(let l): return l.compactMap { $0?.asText }.joined(separator: ", ")
        case .record:
            for key in ["name", "label", "emoji"] {
                if let v = self[key] { return v.asText }
            }
            return jsonText(pretty: false)
        }
    }

    /// A number, where the value reads as one.
    var asNumber: Double? {
        switch self {
        case .number(let n): n
        case .bool(let b): b ? 1 : 0
        case .text(let s): Double(s.trimmingCharacters(in: .whitespaces))
        default: Double(asText)
        }
    }

    static func format(_ n: Double) -> String {
        n.wholeValue.map { String($0) } ?? String(format: "%.3f", n)
    }

    /// The value as plain data, for a .json file and Raw data.
    var plain: Any {
        switch self {
        case .text(let s): s
        case .number(let n): n.wholeValue.map { $0 as Any } ?? n
        case .bool(let b): b
        case .audio(let a): ["audio": a.name, "seconds": (a.duration * 10).rounded() / 10]
        case .image(let p): ["image": p.name, "width": p.width, "height": p.height]
        case .file(let url): ["file": url.path]
        case .stroke(let s): ["points": s.points.map { ["x": $0.x, "y": $0.y] }]
        case .shape(let s): ["kind": s.kind]
        case .list(let l), .stream(let l): l.map { $0?.plain ?? NSNull() }
        case .record(let f): Dictionary(f.map { ($0.0, $0.1.plain) }, uniquingKeysWith: { a, _ in a })
        }
    }

    func jsonText(pretty: Bool = true) -> String {
        let object = plain
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object, options: pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys])
        else { return string ?? "\(object)" }
        return String(decoding: data, as: UTF8.self)
    }
}

// `Value` alone is ambiguous here: Optional has a generic parameter of that name.
extension Optional where Wrapped == Flow.Value {
    var asText: String { self?.asText ?? "" }
}
