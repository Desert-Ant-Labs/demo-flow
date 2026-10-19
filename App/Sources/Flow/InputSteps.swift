import Foundation

/// The sample recordings and photos that come with the app. A flow names them
/// as the web app does ("/samples/jfk.wav"), so the same YAML opens in both.
enum Samples {
    static let root = Bundle.main.resourceURL!.appending(path: "Samples")

    static let audio: [(path: String, label: String)] = [
        ("/samples/voice-memo-2.wav", "Voice memo with contact details"),
        ("/samples/ant-ventures.wav", "Ant ventures, one minute"),
        ("/samples/ant-ventures-3min.wav", "Ant ventures, three minutes"),
        ("/samples/designing-on-device.wav", "Designing on device"),
        ("/samples/clear/room.wav", "Room echo"),
        ("/samples/clear/outdoor-noise.wav", "Outdoor noise"),
        ("/samples/clear/interview.wav", "Interview"),
        ("/samples/clear/podcast.wav", "Podcast"),
        ("/samples/clear/talk.wav", "Talk"),
        ("/samples/clear/nature.wav", "Nature"),
        ("/samples/jfk.wav", "Ask not (1961)"),
    ]

    static let trip = (1...23).map { String(format: "/samples/photos/%03d.jpg", $0) }

    static let people = [
        "couple-chatting-at-cafe", "man-bleached-hair-smiling-at-phone", "person-on-checkered-floor-crowd",
        "redhead-selfie-by-mural", "redhead-selfie-graffiti-wall", "redhead-with-phone-closeup",
        "silhouettes-at-window-table", "silhouettes-behind-glass", "three-friends-sunset-palms",
        "two-friends-at-desk-overhead", "two-friends-city-walk-winter", "two-people-chatting-against-sky",
        "two-people-in-soft-light", "two-people-on-colorful-street", "two-people-reading-book-together",
        "two-people-with-laptop-glow", "two-women-laughing-with-phones", "two-women-sharing-phones-laughing",
        "two-women-taking-selfie", "woman-at-street-cafe", "woman-brown-coat-taking-selfie",
        "woman-bucket-hat-with-phone", "woman-gazing-through-crowd", "woman-hand-reaching-toward-camera",
        "woman-in-busy-restaurant", "woman-long-hair-smiling-at-cafe", "woman-looking-up-blue-sky",
        "woman-on-beach-with-phone", "woman-selfie-european-city-dusk", "woman-smiling-at-phone-dark-bg",
        "woman-standing-still-in-crowd", "woman-still-in-crosswalk-blur", "woman-trenchcoat-blurred-crowd",
        "woman-yellow-jacket-with-phone", "young-man-golden-hour-backlight",
    ].map { "/samples/people/\($0).jpg" }

    static let portraits = [
        "two-women-taking-selfie", "couple-chatting-at-cafe", "woman-looking-up-blue-sky",
        "redhead-selfie-by-mural", "woman-still-in-crosswalk-blur",
    ].map { "/samples/people/\($0).jpg" }

    /// A sample's file in the app, or a file of your own by its path.
    static func url(_ path: String) -> URL {
        if path.hasPrefix("/samples/") { return root.appending(path: String(path.dropFirst("/samples/".count))) }
        if path.hasPrefix("~") { return URL(filePath: (path as NSString).expandingTildeInPath) }
        if path.hasPrefix("http"), let url = URL(string: path), url.path.hasPrefix("/samples/") {
            return Self.url(url.path)
        }
        return URL(filePath: path)
    }

    /// The small copy in thumbs/ next to a sample photo, when it has one.
    static func thumb(_ path: String) -> URL {
        let url = url(path)
        let thumb = url.deletingLastPathComponent().appending(path: "thumbs").appending(path: url.lastPathComponent)
        return FileManager.default.fileExists(atPath: thumb.path) ? thumb : url
    }

    static func label(for url: URL) -> String {
        audio.first { Self.url($0.path) == url }?.label ?? url.deletingPathExtension().lastPathComponent
    }

    /// How a file of your own is kept in a flow: its path, with your home
    /// folder as ~, so the flow still finds it on another of your Macs.
    static func path(for url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }
}

/// The board size the Sketch step draws on.
let sketchSize = CGSize(width: 236, height: 180)

/// Strokes as the YAML keeps them: lists of {x, y}.
func strokes(_ json: JSON?) -> [[CGPoint]] {
    (json?.array ?? []).map { stroke in
        let points = stroke.array ?? stroke.object?["points"]?.array ?? []
        return points.compactMap { p in
            guard let o = p.object, let x = o["x"]?.number, let y = o["y"]?.number else { return nil }
            return CGPoint(x: x, y: y)
        }
    }.filter { $0.count > 2 }
}

/// The Sketch step keeps each stroke as a list of points, the Whiteboard as
/// {points: [...]}, as the web app does.
func strokesJSON(_ strokes: [[CGPoint]], wrapped: Bool = false) -> JSON {
    .array(strokes.map { stroke in
        let points = JSON.array(stroke.map { .object(["x": .number(Double(($0.x * 10).rounded()) / 10), "y": .number(Double(($0.y * 10).rounded()) / 10)]) })
        return wrapped ? .object(["points": points]) : points
    })
}

enum InputSteps {
    static let all: [StepDef] = [text, textlist, record, audio, image, photos, sketch, whiteboard]

    static let text = StepDef(
        type: "text", title: "Text", description: "Anything you type or paste",
        category: .input, outputs: [Port(id: "text", type: .text, label: "Text"),
                                    Port(id: "lines", type: .text, label: "Lines", each: "line"),
                                    Port(id: "sentences", type: .text, label: "Sentences", each: "sentence"),
                                    Port(id: "paragraphs", type: .text, label: "Paragraphs", each: "paragraph")],
        defaults: ["text": ""], pick: Pick(defaults: ["text"])
    ) { run in
        let text = run.params["text"]?.string ?? ""
        return [
            "text": .text(text),
            "lines": .list(Segment.lines.split(text).map { .text($0) }),
            "sentences": .list(Segment.sentences.split(text).map { .text($0) }),
            "paragraphs": .list(Segment.paragraphs.split(text).map { .text($0) }),
        ]
    }

    static let textlist = StepDef(
        type: "textlist", title: "Text list", description: "Several texts, one entry each",
        category: .input, outputs: [Port(id: "items", type: .any, label: "Texts", each: "text")], defaults: ["items": ["", ""]], width: 380
    ) { run in
        let items = (run.params["items"]?.strings ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return items.isEmpty ? [:] : ["items": .list(items.map { .text($0) })]
    }

    static let audio = StepDef(
        type: "audio", title: "Audio", description: "Record, open, or pick a sample",
        category: .input, outputs: [Port(id: "audio", type: .audio, label: "Audio")],
        defaults: ["sample": .string(Samples.audio[0].path)]
    ) { run in
        guard let path = run.params["file"]?.string ?? run.params["sample"]?.string, !path.isEmpty else { return [:] }
        return ["audio": .audio(try await MediaCache.shared.audio(Samples.url(path)))]
    }

    /// The microphone, or a whole meeting: what is heard is the flow's input,
    /// as a recording, as words Voz wrote while it recorded, or both.
    static let record = StepDef(
        type: "record", title: "Record", description: "Record from the microphone, or a whole call",
        category: .input,
        outputs: [Port(id: "audio", type: .audio, label: "Recording"),
                  Port(id: "text", type: .text, label: "Transcript"),
                  Port(id: "labeled", type: .text, label: "Who said what"),
                  Port(id: "sentences", type: .text, label: "Sentences", each: "sentence"),
                  Port(id: "words", type: .any, label: "Words with timings"),
                  Port(id: "title", type: .text, label: "Title")],
        pick: Pick(defaults: ["audio"])
    ) { run in try await Recording.outputs(run.params) }

    static let image = StepDef(
        type: "image", title: "Photo", description: "Open or pick a photo",
        category: .input, outputs: [Port(id: "image", type: .image, label: "Photo")],
        defaults: ["sample": .string(Samples.portraits[0])]
    ) { run in
        guard let path = run.params["file"]?.string ?? run.params["sample"]?.string, !path.isEmpty else { return [:] }
        return ["image": .image(try await MediaCache.shared.photo(Samples.url(path)))]
    }

    static let photos = StepDef(
        type: "photos", title: "Photos", description: "Several photos at once, as a list",
        category: .input, outputs: [Port(id: "photos", type: .image, label: "Photos", each: "photo")],
        defaults: ["samples": .array(Samples.portraits.map { .string($0) })], width: 400
    ) { run in
        let paths = (run.params["samples"]?.strings ?? []) + (run.params["files"]?.strings ?? [])
        var photos: [Value?] = []
        for path in paths {
            if let photo = try? await MediaCache.shared.photo(Samples.url(path)) { photos.append(.image(photo)) }
        }
        run.context.missed(paths.count - photos.count, of: paths.count, "photos")
        return photos.isEmpty ? [:] : ["photos": .list(photos)]
    }

    static let sketch = StepDef(
        type: "sketch", title: "Sketch", description: "Draw with the mouse or trackpad",
        category: .input,
        outputs: [Port(id: "image", type: .image, label: "Drawing"), Port(id: "stroke", type: .stroke, label: "Stroke")]
    ) { run in
        var all = strokes(run.params["strokes"])
        if all.isEmpty { all = strokes(.array([run.params["points"] ?? .array([])])) }
        guard let last = all.last else { return [:] }
        var out: Outputs = ["stroke": .stroke(Stroke(points: last))]
        if let image = Media.drawing(strokes: all) { out["image"] = .image(image) }
        return out
    }

    static let whiteboard = StepDef(
        type: "whiteboard", title: "Whiteboard", description: "Draw as many shapes as you like",
        category: .input,
        outputs: [Port(id: "image", type: .image, label: "Drawing"), Port(id: "strokes", type: .any, label: "Strokes", each: "stroke")],
        width: 380
    ) { run in
        let all = strokes(run.params["strokes"] ?? run.params["seed"])
        guard !all.isEmpty else { return [:] }
        var out: Outputs = ["strokes": .list(all.map { .stroke(Stroke(points: $0)) })]
        if let image = Media.drawing(strokes: all) { out["image"] = .image(image) }
        return out
    }
}

/// How the Record step records, from its settings.
enum Recording {
    /// What a recording's settings hold, as outputs: the recording, the words
    /// Voz wrote, and a title. Shared by Record and the steps that record on
    /// their own.
    static func outputs(_ params: Params) async throws -> Outputs {
        var out: Outputs = [:]
        if let path = params["file"]?.string, !path.isEmpty {
            out["audio"] = .audio(try await MediaCache.shared.audio(Samples.url(path)))
        }
        let text = params["transcript"]?.string ?? ""
        if !text.isEmpty {
            out["text"] = .text(text)
            out["sentences"] = .list(Segment.sentences.split(text).map { .text($0) })
            let words = words(params["words"]), turns = turns(params["turns"])
            out["words"] = .list(words.map {
                .record([("text", .text($0.text)), ("start", .number($0.start)), ("end", .number($0.end))])
            })
            if Speakers.told(words, turns) { out["labeled"] = .text(Speakers.label(words, turns, names: names(params["names"]))) }
        }
        if !out.isEmpty { out["title"] = .text(title(params, transcript: text)) }
        return out
    }

    static func isMeeting(_ params: Params) -> Bool { params["source"]?.string == "meeting" }

    /// What to call a recording: the title it was given, as a call's calendar
    /// event; for a meeting otherwise "Meeting"; for a note its first words.
    static func title(_ params: Params, transcript: String) -> String {
        if let given = params["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !given.isEmpty { return given }
        if isMeeting(params) { return "Meeting" }
        let words = transcript.split(whereSeparator: \.isWhitespace).prefix(6)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
        guard let first = words.first else { return "Note" }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }

    /// Voz writes the words as it records: on for a meeting unless turned off.
    static func transcribes(_ params: Params) -> Bool { params["transcribe"]?.bool ?? isMeeting(params) }

    /// The recording is kept as a file: off for a transcribed meeting unless
    /// turned on, and always on when nothing is transcribed.
    static func keeps(_ params: Params) -> Bool { !transcribes(params) || (params["keep"]?.bool ?? !isMeeting(params)) }

    /// Who tells the voices apart: on for a meeting that is transcribed, unless turned off.
    static func labelsSpeakers(_ params: Params) -> Bool { transcribes(params) && (params["speakers"]?.bool ?? isMeeting(params)) }

    static func options(_ params: Params) -> RecordingOptions {
        RecordingOptions(keepsRecording: keeps(params), transcribes: transcribes(params), labelsSpeakers: labelsSpeakers(params))
    }

    /// The outputs to show for the settings: the recording, the words, or both.
    static func fields(_ params: Params) -> JSON {
        .array((keeps(params) ? ["audio"] : []) + (labelsSpeakers(params) ? ["labeled", "title"] : transcribes(params) ? ["text", "title"] : []))
    }

    /// What a recording left, as the step's settings.
    static func params(_ take: Take) -> Params {
        var p: Params = ["file": take.audio.map { .string(Samples.path(for: $0)) } ?? .null]
        if let transcript = take.transcript {
            p["transcript"] = .string(transcript.text)
            p["words"] = .array(transcript.words.map {
                .array([.string($0.text), .number(($0.start * 100).rounded() / 100), .number(($0.end * 100).rounded() / 100)]
                    + ($0.speaker.map { [.number(Double($0))] } ?? []))
            })
            p["turns"] = transcript.turns.isEmpty ? .null : .array(transcript.turns.map {
                .array([.number(($0.start * 100).rounded() / 100), .number(($0.end * 100).rounded() / 100), .number(Double($0.speaker))])
            })
            p["names"] = transcript.names.isEmpty ? .null : .array(transcript.names.sorted { $0.key < $1.key }.map {
                .array([.number(Double($0.key)), .string($0.value)])
            })
        } else {
            p["transcript"] = .null
            p["words"] = .null
            p["turns"] = .null
            p["names"] = .null
        }
        return p
    }

    /// What each voice was called, as `[speaker, name]` pairs.
    static func names(_ json: JSON?) -> [Int: String] {
        var names: [Int: String] = [:]
        for pair in json?.array ?? [] {
            guard let a = pair.array, a.count == 2, let speaker = a[0].int, let name = a[1].string else { continue }
            names[speaker] = name
        }
        return names
    }

    static func turns(_ json: JSON?) -> [SpeakerTurn] {
        (json?.array ?? []).compactMap { t in
            guard let a = t.array, a.count == 3, let start = a[0].number, let end = a[1].number, let speaker = a[2].int else { return nil }
            return SpeakerTurn(start: start, end: end, speaker: speaker)
        }
    }

    static func words(_ json: JSON?) -> [Transcript.Word] {
        (json?.array ?? []).compactMap { w in
            guard let a = w.array, a.count >= 3, let text = a[0].string, let start = a[1].number, let end = a[2].number else { return nil }
            return Transcript.Word(text: text, start: start, end: end, speaker: a.count > 3 ? a[3].int : nil)
        }
    }
}

extension StepDef {
    /// The models a step runs with these settings: its own, and Voz for a
    /// Record step that transcribes as it records.
    func models(_ params: Params) -> [ModelID] {
        if let model { return [model] }
        let records = type == "record" || type == "call" || (type == "shortcut" && (params["takes"]?.string ?? "voice") == "voice")
        guard records, Recording.transcribes(params) else { return [] }
        return Recording.labelsSpeakers(params) ? [.voz, .who] : [.voz]
    }
}
