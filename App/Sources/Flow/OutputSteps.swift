import AVFoundation
import Foundation

/// The system voice, for the Speak step.
@MainActor
enum Voice {
    private static let synthesizer = AVSpeechSynthesizer()

    static func speak(_ text: String, language: String?) {
        guard !text.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        if let language, !language.isEmpty { utterance.voice = AVSpeechSynthesisVoice(language: language) }
        synthesizer.speak(utterance)
    }
}

enum OutputSteps {
    static let all: [StepDef] = [gallery, table, view, folder, speak, cleanboard]

    static let gallery = StepDef(
        type: "gallery", title: "Gallery", description: "A grid of photos, with captions if you have them",
        category: .output,
        inputs: [Port(id: "photos", type: .image, label: "Photos", list: true),
                 Port(id: "captions", type: .any, label: "Captions", list: true, optional: true)],
        noMap: true, width: 460, resizable: true
    ) { _ in [:] }

    static let table = StepDef(
        type: "table", title: "Table", description: "Line up results item by item",
        category: .output,
        inputs: ["a", "b", "c"].map { Port(id: $0, type: .any, label: $0, optional: true) },
        defaults: ["columns": ""], noMap: true, width: 620, resizable: true
    ) { _ in [:] }

    static let view = StepDef(
        type: "view", title: "Result", description: "The answer, to read, copy, save, or share",
        category: .output,
        inputs: [Port(id: "value", type: .any, label: "Value")],
        noMap: true, resizable: true, featured: true
    ) { _ in [:] }

    /// Writes on every run when `auto` is on, except on the app's samples;
    /// otherwise the card's button does.
    static let folder = StepDef(
        type: "folder", title: "Save to folder", description: "Write the result into a folder on this Mac",
        category: .output,
        inputs: [Port(id: "value", type: .any, label: "Value", list: true), Port(id: "a", type: .any, label: "Name from", optional: true)],
        defaults: ["auto": true, "name": "result"], noMap: true, writes: true
    ) { run in
        guard run.params["auto"]?.bool ?? true, !run.context.samples, let path = run.params["folder"]?.string, !path.isEmpty,
              let value = run.inputs["value"]
        else { return [:] }
        let pattern = run.params["name"]?.string ?? "result"
        // A name made from a value waits for that value, so a flow that has
        // not run yet writes nothing.
        if pattern.contains(#/\{\{\s*a\s*\}\}/#), run.inputs["a"] == nil { return [:] }
        let name = SaveTo.fileName(pattern, a: run.inputs["a"]?.present.first)
        let folder = SaveTo.resolve(path)
        guard run.context.mayChange([folder]) else {
            run.context.note = "Run the flow to save"
            return [:]
        }
        try FolderWriter.write(value, to: folder, name: name)
        return [:]
    }

    static let speak = StepDef(
        type: "speak", title: "Speak", description: "Read text aloud with the system voice",
        category: .output,
        inputs: [Port(id: "text", type: .text, label: "Text"), Port(id: "lang", type: .text, label: "Language", optional: true)],
        defaults: ["auto": false], noMap: true
    ) { run in
        if run.params["auto"]?.bool == true {
            let text = run.inputs["text"].asText, language = run.inputs["lang"]?.asText
            await MainActor.run { Voice.speak(text, language: language) }
        }
        return [:]
    }

    static let cleanboard = StepDef(
        type: "cleanboard", title: "Clean whiteboard", description: "The shapes, drawn clean",
        category: .output,
        inputs: [Port(id: "shapes", type: .any, label: "Shapes", list: true)],
        noMap: true, width: 380
    ) { _ in [:] }
}

/// Writes values as files, for the Save to folder step: text as .txt or .md, a
/// table as .csv, photos as their files, audio as .wav, anything else as .json.
enum FolderWriter {
    /// Returns the files it wrote. A file it wrote before is replaced, so a
    /// flow that runs again keeps one copy of its result, not one per run.
    /// A file of yours with the same name is left alone and the new one gets
    /// a number, as "notes-2.md", and so does a second file of the same name
    /// in one write.
    @discardableResult
    static func write(_ value: Value, to folder: URL, name: String) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = name.isEmpty ? "result" : name
        var written: [URL] = []
        let fm = FileManager.default
        func place(_ file: String) -> URL {
            let first = folder.appending(path: file)
            let stem = first.deletingPathExtension().lastPathComponent, ext = first.pathExtension
            var url = first, k = 2
            while written.contains(url) || (fm.fileExists(atPath: url.path(percentEncoded: false)) && !isOurs(url)) {
                url = folder.appending(path: ext.isEmpty ? "\(stem)-\(k)" : "\(stem)-\(k).\(ext)")
                k += 1
            }
            return url
        }
        func put(_ data: Data, _ file: String) throws {
            let url = place(file)
            let new = !fm.fileExists(atPath: url.path(percentEncoded: false))
            try data.write(to: url, options: .atomic)
            markOurs(url)
            FileJournal.written(url, new: new)
            written.append(url)
        }
        func copy(_ file: URL) throws {
            // A file already in the folder stays where it is.
            if folder.appending(path: file.lastPathComponent).standardizedFileURL == file.standardizedFileURL {
                written.append(file)
                return
            }
            let to = place(file.lastPathComponent)
            let new = !fm.fileExists(atPath: to.path(percentEncoded: false))
            if !new { try fm.removeItem(at: to) }
            try fm.copyItem(at: file, to: to)
            markOurs(to)
            FileJournal.written(to, new: new)
            written.append(to)
        }
        func photo(_ p: Photo, _ fallback: String) throws {
            if let file = p.file {
                try copy(file)
            } else {
                try put(Media.png(p.image), fallback + ".png")
            }
        }
        let items = value.present
        let isRecord = { (v: Value) in if case .record = v { true } else { false } }
        switch value {
        case .image(let p): try photo(p, base)
        case .file(let url): try copy(url)
        case .audio(let a): try put(Media.wav(a), base + ".wav")
        case .text(let t): try put(Data(t.utf8), base + (looksLikeMarkdown(t) ? ".md" : ".txt"))
        case .number, .bool: try put(Data(value.asText.utf8), base + ".txt")
        case .list, .stream:
            if !items.isEmpty && items.allSatisfy({ $0.photo != nil }) {
                for (i, v) in items.enumerated() { try photo(v.photo!, "\(base)-\(i + 1)") }
            } else if !items.isEmpty && items.allSatisfy({ if case .file = $0 { true } else { false } }) {
                for v in items { try copy(v.fileURL!) }
            } else if !items.isEmpty && items.allSatisfy({ $0.audio != nil }) {
                for (i, v) in items.enumerated() { try put(Media.wav(v.audio!), "\(base)-\(i + 1).wav") }
            } else if !items.isEmpty && items.allSatisfy(isRecord) {
                try put(Data(CSV.text(items).utf8), base + ".csv")
            } else if items.allSatisfy({ $0.string != nil }) {
                try put(Data(items.map(\.asText).joined(separator: "\n").utf8), base + ".txt")
            } else {
                try put(Data(value.jsonText().utf8), base + ".json")
            }
        default:
            try put(Data(value.jsonText().utf8), base + ".json")
        }
        return written
    }

    /// Marks the files this app writes, so it can tell them from yours on
    /// any later run.
    private static let mark = "com.desertant.flow.written"

    static func isOurs(_ url: URL) -> Bool { FileMark.get(url, mark) != nil }

    private static func markOurs(_ url: URL) { FileMark.set(url, mark, "1") }

    private static func looksLikeMarkdown(_ s: String) -> Bool {
        s.contains(#/(?m)^(#{1,6} |\s*[-*] |\s*\d+\. |> )|\*\*[^*]+\*\*/#)
    }
}

/// A note kept on a file itself, in an extended attribute, so it travels
/// with the file and needs no list of its own.
enum FileMark {
    static func get(_ url: URL, _ name: String) -> String? {
        url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path else { return nil }
            let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard size >= 0 else { return nil }
            var bytes = [UInt8](repeating: 0, count: size)
            guard getxattr(path, name, &bytes, size, 0, XATTR_NOFOLLOW) == size else { return nil }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    static func set(_ url: URL, _ name: String, _ value: String) {
        let bytes = Array(value.utf8)
        _ = url.withUnsafeFileSystemRepresentation { path in
            path.map { setxattr($0, name, bytes, bytes.count, 0, XATTR_NOFOLLOW) }
        }
    }
}
