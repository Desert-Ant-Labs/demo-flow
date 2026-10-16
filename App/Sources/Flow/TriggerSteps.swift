import Foundation
import UniformTypeIdentifiers

/// The steps a flow can start with to run on its own: when a call starts,
/// when files arrive in a folder, on a schedule, or when you press a
/// shortcut. Each is an input like any other, so Run Again still works by
/// hand; the Mac sets them off once the flow is turned on.
enum TriggerSteps {
    static let all: [StepDef] = [call, watch, schedule, shortcut]
    static let types: Set<String> = Set(all.map(\.type))

    static func isTrigger(_ type: String) -> Bool { types.contains(type) }

    /// The outputs a recording leaves, shared by the call and shortcut steps.
    private static let heard: [Port] = [
        Port(id: "text", type: .text, label: "Transcript"),
        Port(id: "labeled", type: .text, label: "Who said what"),
        Port(id: "sentences", type: .text, label: "Sentences", each: "sentence"),
        Port(id: "words", type: .any, label: "Words with timings"),
        Port(id: "title", type: .text, label: "Title"),
        Port(id: "audio", type: .audio, label: "Recording"),
    ]

    static let call = StepDef(
        type: "call", title: "When a call starts", description: "Writes down each call in the apps you pick, as it happens",
        category: .input, outputs: heard,
        defaults: ["source": "meeting", "apps": .array(CallApps.allIDs.map { .string($0) })],
        pick: Pick(defaults: ["labeled", "title"]), width: 400
    ) { run in try await Recording.outputs(run.params) }

    static let watch = StepDef(
        type: "watch", title: "When files arrive", description: "Runs on each batch of new files in a folder",
        category: .input,
        outputs: [Port(id: "photos", type: .image, label: "Photos", each: "photo"),
                  Port(id: "audio", type: .audio, label: "Recordings", each: "recording"),
                  Port(id: "text", type: .text, label: "Texts", each: "text"),
                  Port(id: "files", type: .any, label: "Files", each: "file")],
        defaults: ["folder": ""], pick: Pick(defaults: ["photos"]), width: 400
    ) { run in
        let paths = (run.params["files"]?.strings).flatMap { $0.isEmpty ? nil : $0 } ?? run.params["samples"]?.strings ?? []
        return try await Arrivals.outputs(paths.map(Samples.url), context: run.context)
    }

    static let schedule = StepDef(
        type: "schedule", title: "On a schedule", description: "Runs at a time of day, on the days you pick",
        category: .input, defaults: ["hour": 9, "minute": 0, "days": .array((2...6).map { .number(Double($0)) })]
    ) { _ in [:] }

    static let shortcut = StepDef(
        type: "shortcut", title: "When you press a shortcut", description: "Runs from anywhere on your Mac with a key you choose",
        category: .input,
        outputs: heard + [Port(id: "photos", type: .image, label: "Photos", each: "photo"),
                          Port(id: "files", type: .any, label: "Files", each: "file")],
        defaults: ["takes": "voice", "transcribe": true, "keep": false],
        pick: Pick(defaults: ["text", "title"]), width: 400
    ) { run in
        switch run.params["takes"]?.string ?? "voice" {
        case "voice": return try await Recording.outputs(run.params)
        case "clipboard":
            var out = try await Arrivals.outputs((run.params["files"]?.strings ?? []).map(Samples.url), context: run.context)
            if let text = run.params["text"]?.string, !text.isEmpty {
                out["text"] = .text(text)
                out["sentences"] = .list(Segment.sentences.split(text).map { .text($0) })
            }
            return out
        default: return [:]
        }
    }
}

/// What a trigger step hands on from files: photos, recordings, texts, and
/// the files themselves, each as a list.
enum Arrivals {
    /// A file that cannot be read is left out of its list, and `context`
    /// hears how many were.
    static func outputs(_ urls: [URL], context: RunContext? = nil) async throws -> Outputs {
        guard !urls.isEmpty else { return [:] }
        var photos: [Value?] = [], audio: [Value?] = [], texts: [Value?] = []
        var tried = 0, failed = 0
        for url in urls {
            let before = photos.count + audio.count + texts.count
            switch kind(of: url) {
            case .photo: if let p = try? await MediaCache.shared.photo(url) { photos.append(.image(p)) }
            case .audio: if let a = try? await MediaCache.shared.audio(url) { audio.append(.audio(a)) }
            case .text: if let t = try? String(contentsOf: url, encoding: .utf8) { texts.append(.text(t)) }
            case nil: continue
            }
            tried += 1
            if photos.count + audio.count + texts.count == before { failed += 1 }
        }
        context?.missed(failed, of: tried, "files")
        var out: Outputs = ["files": .list(urls.map { .file($0) })]
        if !photos.isEmpty { out["photos"] = .list(photos) }
        if !audio.isEmpty { out["audio"] = .list(audio) }
        if !texts.isEmpty { out["text"] = .list(texts) }
        return out
    }

    enum Kind { case photo, audio, text }

    static func kind(of url: URL) -> Kind? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .image) { return .photo }
        if type.conforms(to: .audio) || type.conforms(to: .audiovisualContent) { return .audio }
        if type.conforms(to: .text) { return .text }
        return nil
    }
}
