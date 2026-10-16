import Foundation

/// Runs one call at a time, in order. A model instance is not safe to call
/// twice at once, and an actor would not stop that: it lets a second call in
/// while the first is suspended inside the model.
final class Serial: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let task: Task<T, Error> = lock.withLock {
            let previous = tail
            let task = Task {
                await previous?.value
                return try await work()
            }
            tail = Task { _ = try? await task.value }
            return task
        }
        return try await task.value
    }
}

/// What every model wrapper offers the hub.
protocol ModelRunner: Sendable {
    /// Whether the weights are on this Mac already.
    func isDownloaded() -> Bool
    /// Downloads if need be, then loads and specializes the model for this Mac.
    /// Progress runs from 0 to 1 while downloading.
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws
}

// MARK: Results the steps read, in this app's own words. The SDKs' types stay
// in their wrapper files, where their names cannot clash with SwiftUI's.

struct Transcript: Sendable {
    struct Word: Sendable {
        let text: String
        let start: Double
        let end: Double
        /// Who said it, when that is known from where it was heard, as on a call.
        var speaker: Int?
    }

    let text: String
    let words: [Word]
    /// Who spoke when, when Who listened too.
    var turns: [SpeakerTurn] = []
    /// What each voice is called, as it was named while the call recorded.
    var names: [Int: String] = [:]

    /// The words by speaker, a paragraph each time the voice changes:
    /// "Speaker 1: …". Plain text when nobody was told apart.
    var labeled: String { Speakers.told(words, turns) ? Speakers.label(words, turns, names: names) : text }
}

/// One stretch of one voice. Speakers count from 0, in order of first speaking.
struct SpeakerTurn: Sendable, Equatable {
    let start: Double
    let end: Double
    let speaker: Int
}

struct LanguageGuess: Sendable {
    struct Candidate: Sendable {
        let language: String
        let probability: Double
    }

    let language: String
    let reliable: Bool
    let candidates: [Candidate]
}

struct Redacted: Sendable {
    struct Item: Sendable {
        let label: String
        let original: String
        let confidence: Double
        /// Where it is in the text it was found in.
        let range: Range<String.Index>
    }

    let items: [Item]
}

struct Topic: Sendable {
    let name: String
    let score: Double
}

struct Suggestion: Sendable {
    let emoji: String
    let confidence: Double
}

struct Moderation: Sendable {
    let score: Double
    let isNSFW: Bool
}

/// Eye's reading of a photo, in plain data. Boxes are fractions of the
/// picture, top-left origin.
struct PhotoReading: Sendable {
    struct Box: Sendable {
        let x0, y0, x1, y1: Double
        var area: Double { (x1 - x0) * (y1 - y0) }
    }

    struct Found: Sendable {
        let confidence: Double
        let box: Box
    }

    struct Face: Sendable {
        let confidence: Double
        let box: Box
        let smile: Double
        let eyesOpen: Double
        let looking: Double
        let expression: [String: Double]
    }

    var type: [String: Double] = [:]
    var reject: [String: Double] = [:]
    var sensitive: [String: Double] = [:]
    var scenes: [String: Double] = [:]
    var blur: [String: Double] = [:]
    var aesthetic: Double?
    var keeper: Double?
    var cover: Double?
    var sharpness: Double?
    var people: [Found] = []
    var pets: [Found] = []
    var shot: [String: Double] = [:]
    var crops: [(box: Box, score: Double)] = []
    var faces: [Face] = []
    /// Everything, for the Raw data output.
    var detail: Value = .record([])
}
