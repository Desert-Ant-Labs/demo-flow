import Foundation

/// The eleven models, with the copy from their brand cards.
enum ModelID: String, CaseIterable, Identifiable, Sendable {
    case voz, clear, ear, redact, gist, emo, tongue, shapes, moderator, eye, who

    var id: String { rawValue }

    struct Info: Sendable {
        let name: String
        /// The brand category, on the card's pill.
        let kind: String
        /// What it does, in a few words.
        let task: String
        let about: String
        /// The brand color, by its token name.
        let color: String
        /// How much the first run downloads.
        let mb: Double
    }

    var info: Info {
        switch self {
        case .voz: Info(name: "Voz", kind: "Speech recognition", task: "Speech to text", about: "Transcribes speech, with a timing for every word.", color: "dark-teal", mb: 466)
        case .clear: Info(name: "Clear", kind: "Speech enhancement", task: "Clean up speech", about: "Takes background noise and echo out of a recording.", color: "teal", mb: 47)
        case .ear: Info(name: "Ear", kind: "Language identification", task: "Spoken language", about: "Names the language someone is speaking.", color: "light-peach", mb: 10)
        case .redact: Info(name: "Redact", kind: "PII redaction", task: "Remove personal data", about: "Finds and masks names, emails, phone numbers, and addresses.", color: "forest", mb: 24)
        case .gist: Info(name: "Gist", kind: "Content topic tagging", task: "Topics", about: "Names the topic of a text.", color: "stone", mb: 74)
        case .emo: Info(name: "Emo", kind: "Emoji suggestions", task: "Emoji", about: "Picks the emoji that fit a text.", color: "terracotta", mb: 11)
        case .tongue: Info(name: "Tongue", kind: "Language identification", task: "Text language", about: "Names the language a text is written in.", color: "ink", mb: 2)
        case .shapes: Info(name: "Shapes", kind: "Shape recognition", task: "Sketch to shape", about: "Turns a rough stroke into the clean shape it was meant to be.", color: "sand", mb: 1.2)
        case .moderator: Info(name: "Moderator", kind: "Content moderation", task: "Image safety", about: "Checks whether a photo is safe to show.", color: "warm-grey", mb: 9)
        case .eye: Info(name: "Eye", kind: "Image scoring", task: "Photo understanding", about: "Reads a photo: what it shows, the people and faces in it, and whether it is worth keeping.", color: "slate", mb: 63)
        case .who: Info(name: "Who", kind: "Who said what", task: "Speaker labels", about: "Tells the voices in a recording apart, with when each one speaks.", color: "sage", mb: 84)
        }
    }

    var page: URL { URL(string: "https://desertant.com/models/\(rawValue)/")! }
}
