import Foundation
import NaturalLanguage

/// The highest scores first, at most `limit` of them.
private func ranked(_ scores: [String: Double], limit: Int = 8) -> [(label: String, score: Double)] {
    Array(scores.sorted { $0.value > $1.value }.prefix(limit).map { ($0.key, $0.value) })
}

/// Labels and scores as a list of records.
private func scoredList(_ items: [(label: String, score: Double)], key: String = "label") -> Value {
    .list(items.map { .record([(key, .text($0.label)), ("score", .number($0.score))]) })
}

/// Redact finds more names sentence by sentence than in a long passage, so it
/// runs per sentence, and the placeholders are numbered across the whole text:
/// the same name keeps the same tag everywhere.
private func redactBySentence(_ text: String, confidence: Double, context: RunContext) async throws -> (text: String, items: [Redacted.Item]) {
    var tags: [String: String] = [:]
    var perLabel: [String: Int] = [:]
    var items: [Redacted.Item] = []
    var out = ""
    let tokenizer = NLTokenizer(unit: .sentence)
    tokenizer.string = text
    let sentences = tokenizer.tokens(for: text.startIndex..<text.endIndex)
    // Each segment runs to the start of the next sentence, so the text keeps
    // its line breaks.
    let ends = sentences.dropFirst().map(\.lowerBound) + [text.endIndex]
    var start = text.startIndex
    for end in ends {
        let segment = String(text[start..<end])
        start = end
        let found = try await context.timed { try await ModelHub.redact.find(in: segment, confidence: confidence) }
        var at = segment.startIndex
        for item in found.items.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) where item.range.lowerBound >= at {
            let label = snake(item.label)
            let key = "\(label):\(item.original.lowercased())"
            let tag: String
            if let known = tags[key] {
                tag = known
            } else {
                let number = perLabel[label, default: 0] + 1
                perLabel[label] = number
                tag = "[\(label)_\(number)]"
                tags[key] = tag
            }
            out += segment[at..<item.range.lowerBound] + tag
            at = item.range.upperBound
            items.append(item)
        }
        out += segment[at...]
    }
    return (out, items)
}

/// Words with times, as Voz gives them.
func timedWords(_ value: Value?) -> [Transcript.Word] {
    (value?.present ?? []).compactMap { w in
        guard let start = w["start"]?.asNumber, let end = w["end"]?.asNumber else { return nil }
        return Transcript.Word(text: w["text"].asText, start: start, end: end)
    }
}

/// givenName as GIVEN_NAME, as Redact writes its placeholders.
private func snake(_ label: String) -> String {
    label.replacing(#/([a-z])([A-Z])/#) { "\($0.output.1)_\($0.output.2)" }.uppercased()
}

// MARK: Eye

/// Eye's detections that are confident enough and big enough to be real
/// rather than noise.
private func sure<T>(_ list: [T], _ confidence: (T) -> Double, _ box: (T) -> PhotoReading.Box) -> [T] {
    list.filter { confidence($0) >= 0.25 && box($0).area >= 0.003 }
}

func surePeople(_ r: PhotoReading) -> [PhotoReading.Found] { sure(r.people, \.confidence, \.box) }
func surePets(_ r: PhotoReading) -> [PhotoReading.Found] { sure(r.pets, \.confidence, \.box) }
func sureFaces(_ r: PhotoReading) -> [PhotoReading.Face] { sure(r.faces, \.confidence, \.box) }

private let animals = ["Animal", "Pet", "Cat", "Dog", "Bird", "Horse", "Mammal", "Kitten", "Puppy", "Fish", "Reptile"]
private func top(_ scores: [String: Double]) -> String { ranked(scores, limit: 1).first?.label ?? "" }
private func words(_ s: String) -> String { s.replacingOccurrences(of: "_or_", with: " or ").replacingOccurrences(of: "_", with: " ") }

private let why = [
    "forgettable": "nothing special", "accidental": "taken by accident", "unusable": "unusable",
    "bad_framing": "badly framed", "bad_lighting": "too dark or too bright", "test_or_duplicate_shot": "test shot or duplicate",
    "reference_photo": "saved for reference", "low_content": "nothing in it",
]

/// Eye scores every reason on its own, and good photos often score 0.8 on
/// one. What separates a photo to drop is how far the reason beats Eye's own
/// keeper score.
private func keepOrWhy(_ r: PhotoReading) -> String {
    guard let (reason, score) = r.reject.filter({ $0.key != "keeper" }).max(by: { $0.value < $1.value }),
          score >= 0.8, score - (r.reject["keeper"] ?? 0) >= 0.45
    else { return "keeper" }
    if reason == "technical_flaw" {
        let blur = top(r.blur)
        return !blur.isEmpty && blur != "none" ? "blurry" : "poor quality"
    }
    return why[reason] ?? words(reason)
}

/// Scene tags that say how a picture was made rather than what is in it.
private let style: Set<String> = ["Drawing", "Painting", "Handwriting", "Art", "Cartoon", "Sketch", "Illustration", "Child art", "Whiteboard", "Black-and-white"]

/// Eye's best guesses at what a picture shows: the top one, plus up to two
/// more within 15 points of it.
func guesses(_ r: PhotoReading) -> [(label: String, score: Double)] {
    let list = ranked(r.scenes, limit: 40).filter { !style.contains($0.label) }
    let best = list.first?.score ?? 0
    return Array(list.prefix(3).filter { $0.score >= best - 0.15 })
}

/// A score rounded to three places.
private func score(_ v: Double?) -> Value? { v.map { .number(($0 * 1000).rounded() / 1000) } }

struct EyeField: Sendable {
    let group: String
    let id: String
    let label: String
    let read: @Sendable (PhotoReading) -> Value?
}

enum EyeFields {
    static let groups = [("what", "Subject"), ("keeper", "Quality"), ("faces", "Faces"), ("framing", "Framing"), ("all", "Raw data")]
    static let defaults = ["subject", "keeper", "faces"]
    /// The fields that are a score from 0 to 1, which people read as a percentage.
    static let scores: Set<String> = ["keeper", "aesthetic", "cover", "sharp", "smile", "eyesOpen", "looking"]

    static let all: [EyeField] = [
        EyeField(group: "what", id: "subject", label: "What it shows") { .list(guesses($0).map { .text($0.label) }) },
        EyeField(group: "what", id: "scenes", label: "Scenes, scored") { scoredList(ranked($0.scenes, limit: 5)) },
        EyeField(group: "what", id: "type", label: "Photo type") { .text(words(top($0.type))) },
        EyeField(group: "what", id: "animal", label: "Has an animal") { r in .bool(animals.contains { (r.scenes[$0] ?? 0) >= 0.8 }) },
        EyeField(group: "what", id: "people", label: "People") { .number(Double(surePeople($0).count)) },
        EyeField(group: "what", id: "pets", label: "Pets") { .number(Double(surePets($0).count)) },
        EyeField(group: "keeper", id: "keeper", label: "Keeper score") { score($0.keeper) },
        EyeField(group: "keeper", id: "reason", label: "Keeper or reject reason") { .text(keepOrWhy($0)) },
        EyeField(group: "keeper", id: "aesthetic", label: "Looks good") { score($0.aesthetic) },
        EyeField(group: "keeper", id: "cover", label: "Cover score") { score($0.cover) },
        EyeField(group: "keeper", id: "sharp", label: "Sharpness") { score($0.sharpness) },
        EyeField(group: "keeper", id: "blur", label: "Blur") { .text(top($0.blur)) },
        EyeField(group: "keeper", id: "sensitive", label: "Sensitive") { r in
            guard let (k, v) = r.sensitive.max(by: { $0.value < $1.value }), v >= 0.5 else { return .text("none") }
            return .text(words(k))
        },
        EyeField(group: "faces", id: "faces", label: "Faces") { .number(Double(sureFaces($0).count)) },
        EyeField(group: "faces", id: "smile", label: "Smiling") { score(sureFaces($0).map(\.smile).max().map { max(0, $0) }) },
        EyeField(group: "faces", id: "eyesOpen", label: "Open eyes") { score(sureFaces($0).map(\.eyesOpen).min()) },
        EyeField(group: "faces", id: "looking", label: "Eye contact") { score(sureFaces($0).map(\.looking).max()) },
        EyeField(group: "faces", id: "expression", label: "Expression") { .text(words(top(sureFaces($0).first?.expression ?? [:]))) },
        EyeField(group: "framing", id: "shot", label: "Framing") { .text(words(top($0.shot))) },
        EyeField(group: "framing", id: "crop", label: "Best crop") { r in
            guard let b = r.crops.max(by: { $0.score < $1.score })?.box else { return nil }
            return .record([("x0", .number(b.x0)), ("y0", .number(b.y0)), ("x1", .number(b.x1)), ("y1", .number(b.y1))])
        },
        EyeField(group: "all", id: "detail", label: "Everything") { $0.detail },
    ]

    static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}

/// Eye's reading of each photo it ran on, for the card's preview: the boxes
/// it drew need the reading, not just the fields.
actor EyeReadings {
    static let shared = EyeReadings()

    /// Held weakly by photo, so a reading goes when its photo does.
    private let byPhoto = NSMapTable<Photo, Box>.weakToStrongObjects()

    private final class Box {
        let reading: PhotoReading
        init(_ reading: PhotoReading) { self.reading = reading }
    }

    func store(_ r: PhotoReading, for photo: Photo) { byPhoto.setObject(Box(r), forKey: photo) }
    func reading(for photo: Photo) -> PhotoReading? { byPhoto.object(forKey: photo)?.reading }
}

enum ModelSteps {
    static let all: [StepDef] = [voz, who, clear, uhm, ClipsStep.def, ear, redact, tongue, gist, emo, shapes, moderator, eye, duplicates]

    static let voz = StepDef(
        type: "voz", title: "Voz", description: "Speech to text, with word timings",
        category: .model, model: .voz,
        inputs: [Port(id: "audio", type: .audio, label: "Audio")],
        outputs: [Port(id: "text", type: .text, label: "Transcript"), Port(id: "sentences", type: .text, label: "Sentences", each: "sentence"),
                  Port(id: "words", type: .any, label: "Words with timings")],
        pick: Pick(defaults: ["text"])
    ) { run in
        guard let audio = run.inputs["audio"]?.audio else { throw StepError("No audio") }
        let t = try await run.context.timed { try await ModelHub.voz.transcribe(audio.samples, sampleRate: audio.sampleRate) }
        return [
            "text": .text(t.text),
            "sentences": .list(Segment.sentences.split(t.text).map { .text($0) }),
            "words": .list(t.words.map { .record([("text", .text($0.text)), ("start", .number($0.start)), ("end", .number($0.end))]) }),
        ]
    }

    static let who = StepDef(
        type: "who", title: "Who", description: "Who said what, and when",
        category: .model, model: .who,
        inputs: [Port(id: "audio", type: .audio, label: "Audio"),
                 Port(id: "words", type: .any, label: "Words with timings", list: true, optional: true)],
        outputs: [Port(id: "text", type: .text, label: "Who said what"),
                  Port(id: "turns", type: .any, label: "Turns", each: "turn"),
                  Port(id: "speakers", type: .any, label: "Speakers"),
                  Port(id: "lines", type: .any, label: "Lines, with times"),
                  Port(id: "paragraphs", type: .text, label: "Paragraphs", each: "paragraph"),
                  Port(id: "speaker", type: .text, label: "Speaker of each paragraph", each: "paragraph")],
        defaults: ["names": ""], pick: Pick(defaults: ["text"])
    ) { run in
        guard let audio = run.inputs["audio"]?.audio else { throw StepError("No audio") }
        let turns = try await run.context.timed { try await ModelHub.who.diarize(audio.samples, sampleRate: audio.sampleRate) }
        let names = Speakers.names(listed: run.params["names"]?.string ?? "")
        let name = { Speakers.name($0, names) }
        let joined = Speakers.join(turns)
        var out: Outputs = [
            "turns": .list(joined.map { .record([("speaker", .text(name($0.speaker))), ("start", .number($0.start)), ("end", .number($0.end))]) }),
            "speakers": .number(Double(Set(turns.map(\.speaker)).count)),
        ]
        let words = timedWords(run.inputs["words"])
        guard !words.isEmpty else {
            let clock = { Duration.seconds($0).formatted(.time(pattern: .minuteSecond)) }
            out["text"] = .text(joined.map { "\(name($0.speaker)): \(clock($0.start)) to \(clock($0.end))" }.joined(separator: "\n"))
            return out
        }
        let lines = Speakers.lines(words, turns)
        let paragraphs = Speakers.paragraphs(lines).map { (speaker: name($0.speaker), text: $0.lines.map(\.text).joined(separator: " ")) }
        out["text"] = .text(Speakers.label(lines, names: names))
        out["paragraphs"] = .list(paragraphs.map { .text($0.text) })
        out["speaker"] = .list(paragraphs.map { .text($0.speaker) })
        out["lines"] = .list(lines.map {
            .record([("speaker", .text(name($0.speaker))), ("start", .number($0.start)), ("end", .number($0.end)), ("text", .text($0.text))])
        })
        return out
    }

    static let clear = StepDef(
        type: "clear", title: "Clear", description: "Remove noise and echo, level the voice",
        category: .model, model: .clear,
        inputs: [Port(id: "audio", type: .audio, label: "Audio")],
        outputs: [Port(id: "audio", type: .audio, label: "Clean audio")],
        defaults: ["loudness": "podcast"]
    ) { run in
        guard let audio = run.inputs["audio"]?.audio else { throw StepError("No audio") }
        let samples = try Media.resample(audio, to: 48_000)
        let loudness = run.params["loudness"]?.string ?? "podcast"
        let r = try await run.context.timed { try await ModelHub.clear.enhance(samples, loudness: loudness) }
        let clean = AudioClip(samples: r.samples, sampleRate: r.sampleRate, name: "Clean \(audio.name)")
        let stem = (audio.file?.deletingPathExtension().lastPathComponent ?? audio.name) + "_clear"
        return ["audio": .audio(try await Media.written(clean, stem: stem, picture: audio.file))]
    }

    private static func language(_ g: LanguageGuess) -> Outputs {
        [
            "language": .text(g.language),
            "reliable": .bool(g.reliable),
            "candidates": .list(g.candidates.prefix(3).map { .record([("language", .text($0.language)), ("probability", .number($0.probability))]) }),
        ]
    }

    static let uhm = StepDef(
        type: "uhm", title: "Uhm", description: "Every uh, um, and hmm, with times",
        category: .model, model: .uhm,
        inputs: [Port(id: "audio", type: .audio, label: "Audio")],
        outputs: [Port(id: "fillers", type: .any, label: "Filler words", each: "filler"), Port(id: "count", type: .any, label: "Count")],
        pick: Pick(defaults: ["fillers", "count"])
    ) { run in
        guard let audio = run.inputs["audio"]?.audio else { throw StepError("No audio") }
        let samples = try Media.resample(audio, to: 16_000)
        let fillers = try await run.context.timed { try await ModelHub.uhm.fillers(samples) }
        return [
            "fillers": .list(fillers.map {
                .record([("type", .text($0.type)), ("start", .number($0.start)), ("end", .number($0.end)), ("confidence", .number($0.confidence))])
            }),
            "count": .number(Double(fillers.count)),
        ]
    }

    private static let languageOutputs = [
        Port(id: "language", type: .text, label: "Language"), Port(id: "reliable", type: .any, label: "Is sure"),
        Port(id: "candidates", type: .any, label: "Top guesses"),
    ]

    static let ear = StepDef(
        type: "ear", title: "Ear", description: "Which language is spoken",
        category: .model, model: .ear,
        inputs: [Port(id: "audio", type: .audio, label: "Audio")],
        outputs: languageOutputs,
        pick: Pick(defaults: ["language"])
    ) { run in
        guard let audio = run.inputs["audio"]?.audio else { throw StepError("No audio") }
        let samples = try Media.resample(audio, to: 16_000)
        return language(try await run.context.timed { try await ModelHub.ear.identify(samples, sampleRate: 16_000) })
    }

    static let redact = StepDef(
        type: "redact", title: "Redact", description: "Find and mask personal data",
        category: .model, model: .redact,
        inputs: [Port(id: "text", type: .text, label: "Text")],
        outputs: [Port(id: "text", type: .text, label: "Redacted text"), Port(id: "found", type: .any, label: "Result"), Port(id: "count", type: .any, label: "Count")],
        defaults: ["confidence": 0.6], pick: Pick(defaults: ["text"])
    ) { run in
        let confidence = run.params["confidence"]?.number ?? 0.6
        let r = try await redactBySentence(run.inputs["text"].asText, confidence: confidence, context: run.context)
        return [
            "text": .text(r.text),
            "found": .list(r.items.map {
                .record([("label", .text(snake($0.label).replacingOccurrences(of: "_", with: " ").lowercased())),
                         ("text", .text($0.original)), ("confidence", .number($0.confidence))])
            }),
            "count": .number(Double(r.items.count)),
        ]
    }

    static let tongue = StepDef(
        type: "tongue", title: "Tongue", description: "Which language is written",
        category: .model, model: .tongue,
        inputs: [Port(id: "text", type: .text, label: "Text")],
        outputs: languageOutputs,
        pick: Pick(defaults: ["language"])
    ) { run in
        let text = run.inputs["text"].asText
        return language(try await run.context.timed { try await ModelHub.tongue.detect(text) })
    }

    static let gist = StepDef(
        type: "gist", title: "Gist", description: "What it is about, in 36 topics",
        category: .model, model: .gist,
        inputs: [Port(id: "text", type: .text, label: "Text")],
        outputs: [Port(id: "top", type: .text, label: "Topic"), Port(id: "topics", type: .any, label: "All topics")],
        defaults: ["limit": 3], pick: Pick(defaults: ["top"])
    ) { run in
        let text = run.inputs["text"].asText, limit = max(1, run.params["limit"]?.int ?? 3)
        let topics = try await run.context.timed { try await ModelHub.gist.classify(text, topK: limit) }
        return [
            "topics": scoredList(topics.map { ($0.name, $0.score) }, key: "name"),
            "top": .text(topics.first?.name ?? ""),
        ]
    }

    static let emo = StepDef(
        type: "emo", title: "Emo", description: "Emoji that fit the text",
        category: .model, model: .emo,
        inputs: [Port(id: "text", type: .text, label: "Text")],
        outputs: [Port(id: "emoji", type: .text, label: "Emoji"), Port(id: "list", type: .any, label: "Ranked, with scores")],
        defaults: ["limit": 3], pick: Pick(defaults: ["emoji"])
    ) { run in
        let text = run.inputs["text"].asText, limit = max(1, run.params["limit"]?.int ?? 3)
        let list = try await run.context.timed { try await ModelHub.emo.suggestions(text, limit: limit) }
        return [
            "emoji": .text(list.map(\.emoji).joined()),
            "list": .list(list.map { .record([("emoji", .text($0.emoji)), ("confidence", .number($0.confidence))]) }),
        ]
    }

    static let shapes = StepDef(
        type: "shapes", title: "Shapes", description: "Turn a rough stroke into a clean shape",
        category: .model, model: .shapes,
        inputs: [Port(id: "stroke", type: .stroke, label: "Stroke")],
        outputs: [
            Port(id: "image", type: .image, label: "Drawing"),
            Port(id: "kind", type: .text, label: "Shape name"),
            Port(id: "shape", type: .any, label: "Shape, as points"),
        ],
        pick: Pick(defaults: ["image"])
    ) { run in
        guard case .stroke(let stroke) = run.inputs["stroke"] else { throw StepError("No stroke") }
        let shape = try await run.context.timed { try await ModelHub.shapes.recognize(stroke.points) }
        var out: Outputs = ["kind": .text(shape?.kind ?? "none")]
        if let shape {
            out["shape"] = .shape(shape)
            if let image = Media.drawing(shapes: [shape]) { out["image"] = .image(image) }
        }
        return out
    }

    static let moderator = StepDef(
        type: "moderator", title: "Moderator", description: "Is this photo safe to show",
        category: .model, model: .moderator,
        inputs: [Port(id: "image", type: .image, label: "Photo")],
        outputs: [Port(id: "safe", type: .any, label: "Is safe"), Port(id: "score", type: .any, label: "Score"), Port(id: "image", type: .image, label: "Photo")],
        defaults: ["threshold": 0.5], pick: Pick(defaults: ["safe", "image"])
    ) { run in
        guard let photo = run.inputs["image"]?.photo else { throw StepError("No photo") }
        let threshold = run.params["threshold"]?.number ?? 0.5
        let m = try await run.context.timed { try await ModelHub.moderator.analyze(photo.image, threshold: threshold) }
        return ["safe": .bool(!m.isNSFW), "score": .number(m.score), "image": .image(photo)]
    }

    static let eye = StepDef(
        type: "eye", title: "Eye", description: "Scenes, people, faces, and quality",
        category: .model, model: .eye,
        inputs: [Port(id: "image", type: .image, label: "Photo")],
        outputs: EyeFields.all.map { Port(id: $0.id, type: .any, label: $0.label, group: $0.group) },
        pick: Pick(defaults: EyeFields.defaults, suggest: ["type", "reason", "smile"], groups: EyeFields.groups),
        width: 340
    ) { run in
        guard let photo = run.inputs["image"]?.photo else { throw StepError("No photo") }
        let r = try await run.context.timed { try await ModelHub.eye.analyze(photo.image) }
        await EyeReadings.shared.store(r, for: photo)
        var out: Outputs = [:]
        for field in EyeFields.all { out[field.id] = field.read(r) }
        return out
    }
}

extension ModelSteps {
    static let duplicates = StepDef(
        type: "duplicates", title: "Duplicates", description: "The photos to keep from sets of near-duplicates, and the rest",
        category: .logic, model: .eye,
        inputs: [Port(id: "photos", type: .image, label: "Photos", list: true)],
        outputs: [Port(id: "keep", type: .image, label: "Keep", each: "photo"), Port(id: "others", type: .image, label: "The rest", each: "photo"),
                  Port(id: "groups", type: .any, label: "Groups")],
        noMap: true, pick: Pick(defaults: ["keep", "others"])
    ) { run in
        let photos = (run.inputs["photos"]?.present ?? []).compactMap(\.photo)
        let dates = photos.map { $0.file.flatMap(Media.captureDate) }
        let groups = try await run.context.timed {
            try await ModelHub.eye.duplicates(photos.map(\.image), dates: dates.allSatisfy { $0 != nil } ? dates.compactMap { $0 } : nil) {
                run.context.progress($0, photos.count)
            }
        }
        let others = Set(groups.flatMap { $0.dropFirst() })
        return [
            "keep": .list(photos.indices.filter { !others.contains($0) }.map { .image(photos[$0]) }),
            "others": .list(photos.indices.filter(others.contains).map { .image(photos[$0]) }),
            "groups": .list(groups.map { .list($0.map { .image(photos[$0]) }) }),
        ]
    }
}

/// Whether a step's output is a score from 0 to 1, shown and typed as a
/// percentage.
func isScore(_ type: String?, _ output: String) -> Bool {
    switch type {
    case "eye": EyeFields.scores.contains(output)
    case "moderator": output == "score"
    default: false
    }
}
