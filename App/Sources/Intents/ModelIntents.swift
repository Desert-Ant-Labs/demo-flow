import AppIntents
import Foundation
import UniformTypeIdentifiers

/// Runs one model's step outside a flow.
enum ModelAction {
    static func run(_ type: String, _ inputs: [String: Value], params: Params = [:]) async throws -> Outputs {
        guard let def = Steps.byType[type] else { throw StepError("Flow has no \(type) step") }
        if let model = def.model { try await ModelHub.shared.prepare(model) }
        let context = RunContext(id: "shortcut-\(type)") { _, _ in }
        return try await def.run(StepRun(inputs: inputs, params: def.defaults.merging(params) { $1 }, context: context))
    }

    /// A file Shortcuts hands over, somewhere Flow can read it while `read`
    /// runs. A copy made for that is removed afterwards.
    static func local<T>(_ file: IntentFile, _ read: (URL) async throws -> T) async throws -> T {
        if let url = file.fileURL { return try await read(url) }
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Only the name counts: what Shortcuts calls a file never says where
        // to write it.
        let name = (file.filename as NSString).lastPathComponent
        let url = folder.appending(path: ["", ".", "..", "/"].contains(name) ? "file" : name)
        try file.data.write(to: url)
        return try await read(url)
    }

    static func audio(_ file: IntentFile) async throws -> Value {
        .audio(try await local(file) { try await Media.audio($0) })
    }

    static func photo(_ file: IntentFile) async throws -> Value {
        .image(try await local(file) { try Media.photo($0) })
    }
}

struct TranscribeAudio: AppIntent {
    static let title: LocalizedStringResource = "Transcribe Audio with Voz"
    static let description = IntentDescription("Turns speech in a recording into text, on this Mac.")

    @Parameter(title: "Audio", supportedContentTypes: [.audio, .movie])
    var audio: IntentFile

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let out = try await ModelAction.run("voz", ["audio": try await ModelAction.audio(audio)])
        return .result(value: out["text"].asText)
    }
}

struct LabelSpeakers: AppIntent {
    static let title: LocalizedStringResource = "Label Speakers with Who"
    static let description = IntentDescription("Writes down a recording with who said what, on this Mac.")

    @Parameter(title: "Audio", supportedContentTypes: [.audio, .movie])
    var audio: IntentFile

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let clip = try await ModelAction.audio(audio)
        let words = try await ModelAction.run("voz", ["audio": clip])["words"]
        let out = try await ModelAction.run("who", ["audio": clip, "words": words ?? .list([])])
        return .result(value: out["text"].asText)
    }
}

struct CleanAudio: AppIntent {
    static let title: LocalizedStringResource = "Clean Up Audio with Clear"
    static let description = IntentDescription("Removes noise and echo from a recording and levels the voice, on this Mac.")

    @Parameter(title: "Audio", supportedContentTypes: [.audio, .movie])
    var audio: IntentFile

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let out = try await ModelAction.run("clear", ["audio": try await ModelAction.audio(audio)])
        guard let clip = out["audio"]?.audio else { throw StepError("Clear gave no audio") }
        let name = (audio.filename as NSString).deletingPathExtension
        return .result(value: IntentFile(data: Media.wav(clip), filename: "\(name.isEmpty ? "Recording" : name) clean.wav", type: .wav))
    }
}

struct SpokenLanguage: AppIntent {
    static let title: LocalizedStringResource = "Get Spoken Language with Ear"
    static let description = IntentDescription("Names the language spoken in a recording, on this Mac.")

    @Parameter(title: "Audio", supportedContentTypes: [.audio, .movie])
    var audio: IntentFile

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let out = try await ModelAction.run("ear", ["audio": try await ModelAction.audio(audio)])
        return .result(value: languageName(out["language"].asText))
    }
}

struct RedactText: AppIntent {
    static let title: LocalizedStringResource = "Redact Text with Redact"
    static let description = IntentDescription("Masks names, addresses, phone numbers, and other personal data in text, on this Mac.")

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let out = try await ModelAction.run("redact", ["text": .text(text)])
        return .result(value: out["text"].asText)
    }
}

struct WrittenLanguage: AppIntent {
    static let title: LocalizedStringResource = "Get Language of Text with Tongue"
    static let description = IntentDescription("Names the language a text is written in, on this Mac.")

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let out = try await ModelAction.run("tongue", ["text": .text(text)])
        return .result(value: languageName(out["language"].asText))
    }
}

struct TextTopic: AppIntent {
    static let title: LocalizedStringResource = "Get Topic of Text with Gist"
    static let description = IntentDescription("Names what a text is about, from 36 topics, on this Mac.")

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let out = try await ModelAction.run("gist", ["text": .text(text)])
        return .result(value: out["top"].asText)
    }
}

struct SuggestEmoji: AppIntent {
    static let title: LocalizedStringResource = "Suggest Emoji with Emo"
    static let description = IntentDescription("Picks emoji that fit a text, on this Mac.")

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    @Parameter(title: "How Many", default: 3, inclusiveRange: (1, 10))
    var limit: Int

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let out = try await ModelAction.run("emo", ["text": .text(text)], params: ["limit": .number(Double(limit))])
        return .result(value: out["emoji"].asText)
    }
}

struct CheckPhoto: AppIntent {
    static let title: LocalizedStringResource = "Check Photo with Moderator"
    static let description = IntentDescription("Says whether a photo is safe to show, on this Mac.")

    @Parameter(title: "Photo", supportedContentTypes: [.image])
    var photo: IntentFile

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let out = try await ModelAction.run("moderator", ["image": try await ModelAction.photo(photo)])
        guard case .bool(let safe)? = out["safe"] else { throw StepError("Moderator gave no answer") }
        return .result(value: safe)
    }
}

/// What Eye can say about a photo, as Shortcuts offers it.
enum EyeQuestion: String, AppEnum {
    case subject, type, keeper, reason, people, pets, faces, smile, eyesOpen, looking, shot, sharp

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Question"
    static let caseDisplayRepresentations: [EyeQuestion: DisplayRepresentation] = [
        .subject: "Subject",
        .type: "Photo type",
        .keeper: "Keeper score",
        .reason: "Keeper or reject reason",
        .people: "Number of people",
        .pets: "Number of pets",
        .faces: "Number of faces",
        .smile: "Smile",
        .eyesOpen: "Open eyes",
        .looking: "Eye contact",
        .shot: "Framing",
        .sharp: "Sharpness",
    ]
}

struct ReadPhoto: AppIntent {
    static let title: LocalizedStringResource = "Read Photo with Eye"
    static let description = IntentDescription("Answers one question about a photo: what it shows, whether it is a keeper, who is smiling, and more, on this Mac.")

    @Parameter(title: "Photo", supportedContentTypes: [.image])
    var photo: IntentFile

    @Parameter(title: "Question", default: .subject)
    var question: EyeQuestion

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$question) of \(\.$photo) with Eye")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let out = try await ModelAction.run("eye", ["image": try await ModelAction.photo(photo)])
        let field = question.rawValue
        switch out[field] {
        case nil:
            return .result(value: EyeFields.byID[field]?.group == "faces" ? "No face" : "None")
        case .number(let n) where isScore("eye", field):
            return .result(value: "\(Int((n * 100).rounded()))%")
        case .bool(let b):
            return .result(value: b ? "Yes" : "No")
        case let v?:
            return .result(value: v.asText)
        }
    }
}

struct FlowShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TranscribeAudio(), phrases: ["Transcribe audio with \(.applicationName)"],
                    shortTitle: "Transcribe Audio", systemImageName: "waveform")
        AppShortcut(intent: LabelSpeakers(), phrases: ["Label speakers with \(.applicationName)"],
                    shortTitle: "Label Speakers", systemImageName: "person.2.wave.2")
        AppShortcut(intent: CleanAudio(), phrases: ["Clean up audio with \(.applicationName)"],
                    shortTitle: "Clean Up Audio", systemImageName: "waveform.badge.magnifyingglass")
        AppShortcut(intent: SpokenLanguage(), phrases: ["Get the spoken language with \(.applicationName)"],
                    shortTitle: "Spoken Language", systemImageName: "ear")
        AppShortcut(intent: RedactText(), phrases: ["Redact text with \(.applicationName)"],
                    shortTitle: "Redact Text", systemImageName: "eye.slash")
        AppShortcut(intent: WrittenLanguage(), phrases: ["Get the language of text with \(.applicationName)"],
                    shortTitle: "Language of Text", systemImageName: "character.bubble")
        AppShortcut(intent: TextTopic(), phrases: ["Get the topic of text with \(.applicationName)"],
                    shortTitle: "Topic of Text", systemImageName: "tag")
        AppShortcut(intent: SuggestEmoji(), phrases: ["Suggest emoji with \(.applicationName)"],
                    shortTitle: "Suggest Emoji", systemImageName: "face.smiling")
        AppShortcut(intent: CheckPhoto(), phrases: ["Check a photo with \(.applicationName)"],
                    shortTitle: "Check Photo", systemImageName: "checkmark.shield")
        AppShortcut(intent: ReadPhoto(), phrases: ["Read a photo with \(.applicationName)"],
                    shortTitle: "Read Photo", systemImageName: "eye")
    }
}
