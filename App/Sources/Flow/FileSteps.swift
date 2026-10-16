import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Naming, copying, and moving files, for the Rename and Copy or move steps.
enum FileOps {
    /// When a file was made: a photo's capture date, otherwise the file's own.
    static func date(of url: URL) -> Date {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let taken = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
           let date = exifFormat.date(from: taken) {
            return date
        }
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? .now
    }

    private static let exifFormat = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    /// The patterns worth offering: with a value wired into `a` they use it.
    static func suggestions(usesA: Bool) -> [String] {
        usesA
            ? ["{{a}}-{{n}}", "{{date}}-{{a}}-{{n}}", "{{a}}/{{name}}", "{{date}} {{a}}"]
            : ["{{date}}-{{n}}", "{{name}}-{{n}}", "{{date}} {{name}}", "{{date}}-{{time}}"]
    }

    /// A new name for every file, from a pattern. `{{name}}` is the old name,
    /// `{{n}}` the number padded to the size of the batch, `{{date}}` and
    /// `{{time}}` when the file was made, in this Mac's time zone, and
    /// `{{a}}` the value wired in for that file. The extension stays. A slash
    /// in the result makes a folder.
    static func names(for urls: [URL], pattern: String, a: [Value?] = []) -> [String] {
        let width = String(urls.count).count
        var taken = Set<String>()
        return urls.enumerated().map { i, url in
            var stem = fill(pattern, url: url, number: i + 1, width: width, a: i < a.count ? a[i] : nil)
            if stem.isEmpty { stem = url.deletingPathExtension().lastPathComponent }
            let ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension.lowercased()
            var name = stem + ext, k = 2
            while !taken.insert(name.lowercased()).inserted {
                name = "\(stem)-\(k)\(ext)"
                k += 1
            }
            return name
        }
    }

    /// The pattern filled in for one file, cleaned up for the Finder. Empty
    /// when nothing of it is left.
    static func fill(_ pattern: String, url: URL, number: Int = 1, width: Int = 1, a: Value? = nil) -> String {
        // Reading a photo's capture date opens the file, so it waits until
        // the pattern asks for it.
        let filled = Placeholders.fill(pattern, at: { date(of: url) }) { key in
            switch key {
            case "name": url.deletingPathExtension().lastPathComponent
            case "n": String(repeating: "0", count: max(0, width - String(number).count)) + String(number)
            case "a": (a?.present.first).asText
            default: nil
            }
        }
        return filled.split(separator: "/").map(clean).filter { !$0.isEmpty }.joined(separator: "/")
    }

    /// A name the Finder takes: no colons, no control characters, no leading dots.
    private static func clean(_ part: Substring) -> String {
        let bad = CharacterSet(charactersIn: ":\\").union(.controlCharacters).union(.newlines)
        return String(part.unicodeScalars.map { bad.contains($0) ? "-" : Character($0) })
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    enum Action: String, Sendable {
        case copy, move
    }

    /// Copies or moves each file to its new place. A different file already
    /// there is left alone and the new one gets a number, so nothing is
    /// overwritten. A copy that is already there is not made again.
    @discardableResult
    static func apply(_ files: [URL], to targets: [URL], _ action: Action) throws -> [URL] {
        let fm = FileManager.default
        if action == .move, files.contains(where: { $0.path.hasPrefix(Bundle.main.bundlePath + "/") }) {
            throw StepError("The sample files are part of the app and can't be moved or renamed. Copy them instead.")
        }
        return try zip(files, targets).map { from, planned in
            guard from.standardizedFileURL != planned.standardizedFileURL else { return from }
            if sameFile(from, planned) {
                guard action == .move else { return from }
                // Only the case changed: a case-insensitive disk sees one file, so go through a temporary name.
                let temporary = from.deletingLastPathComponent().appending(path: ".\(UUID().uuidString)-\(from.lastPathComponent)")
                try fm.moveItem(at: from, to: temporary)
                try fm.moveItem(at: temporary, to: planned)
                FileJournal.moved(from, to: planned)
                return planned
            }
            try fm.createDirectory(at: planned.deletingLastPathComponent(), withIntermediateDirectories: true)
            var to = planned, k = 2
            while fm.fileExists(atPath: to.path(percentEncoded: false)) {
                if action == .copy, fm.contentsEqual(atPath: from.path(percentEncoded: false), andPath: to.path(percentEncoded: false)) {
                    return to
                }
                let stem = planned.deletingPathExtension().lastPathComponent
                to = planned.deletingLastPathComponent().appending(path: "\(stem)-\(k)").appendingPathExtension(planned.pathExtension)
                k += 1
            }
            switch action {
            case .copy:
                try fm.copyItem(at: from, to: to)
                FileJournal.copied(to: to)
            case .move:
                try fm.moveItem(at: from, to: to)
                FileJournal.moved(from, to: to)
            }
            return to
        }
    }

    /// Whether two paths are the same file on disk, as on a case-insensitive
    /// disk two names that differ only in case are.
    private static func sameFile(_ a: URL, _ b: URL) -> Bool {
        let key = URLResourceKey.fileResourceIdentifierKey
        guard let x = try? a.resourceValues(forKeys: [key]).fileResourceIdentifier,
              let y = try? b.resourceValues(forKeys: [key]).fileResourceIdentifier
        else { return false }
        return x.isEqual(y)
    }

    /// Every file in a folder, without its subfolders or hidden files.
    static func contents(of folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

enum FileSteps {
    static let all: [StepDef] = [files, rename, copy]

    /// Photos come out as photos, so Eye and Moderator can read them; any
    /// other file as itself.
    static let files = StepDef(
        type: "files", title: "Files", description: "Files or whole folders from this Mac, as a list",
        category: .input,
        outputs: [Port(id: "files", type: .any, label: "Files", each: "file")],
        defaults: ["files": .array([]), "folders": .array([])], width: 360
    ) { run in
        let folders = (run.params["folders"]?.strings ?? []).flatMap { FileOps.contents(of: Samples.url($0)) }
        let urls = folders + (run.params["files"]?.strings ?? []).map(Samples.url)
        guard !urls.isEmpty else { return [:] }
        var items: [Value?] = []
        for url in urls {
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
               let photo = try? await MediaCache.shared.photo(url) {
                items.append(.image(photo))
            } else {
                items.append(.file(url))
            }
        }
        return ["files": .list(items)]
    }

    /// Plans the new names on every run, and renames only when asked: a run
    /// of the flow never touches your files by itself.
    static let rename = StepDef(
        type: "rename", title: "Rename", description: "New names for files from a pattern, with dates as YYYY-MM-DD",
        category: .output,
        inputs: [Port(id: "files", type: .any, label: "Files", list: true),
                 Port(id: "a", type: .any, label: "a", list: true, optional: true)],
        outputs: [Port(id: "names", type: .text, label: "New names")],
        defaults: ["pattern": "{{date}}-{{n}}", "mode": "copy", "auto": false], noMap: true, width: 400, writes: true
    ) { run in
        let urls = (run.inputs["files"]?.present ?? []).compactMap(\.fileURL)
        guard !urls.isEmpty else { return [:] }
        let names = FileOps.names(for: urls, pattern: run.params["pattern"]?.string ?? "{{name}}",
                                  a: run.inputs["a"]?.items ?? [])
        if run.params["auto"]?.bool == true, !run.context.samples { try renameNow(urls, names, run.params, run.context) }
        return ["names": .list(names.map { .text($0) })]
    }

    /// Renames or copies on every run, for a flow a trigger runs. Files that
    /// are gone, renamed by an earlier run, are left out.
    private static func renameNow(_ urls: [URL], _ names: [String], _ params: Params, _ context: RunContext) throws {
        let inPlace = params["mode"]?.string == "rename"
        let folder = params["folder"]?.string ?? ""
        guard inPlace || !folder.isEmpty else { return }
        let pairs = zip(urls, names).filter { FileManager.default.fileExists(atPath: $0.0.path(percentEncoded: false)) }
        let targets = pairs.map { url, name in
            (inPlace ? url.deletingLastPathComponent() : SaveTo.resolve(folder)).appending(path: name)
        }
        // Renaming in place moves the files themselves, so they count too.
        guard context.mayChange(targets + (inPlace ? pairs.map(\.0) : [])) else {
            context.note = inPlace ? "Run the flow to rename" : "Run the flow to copy"
            return
        }
        try FileOps.apply(pairs.map(\.0), to: targets, inPlace ? .move : .copy)
    }

    /// Copies on every run when asked to, so a folder stays in step with the
    /// flow. Moving only happens from the button.
    static let copy = StepDef(
        type: "copy", title: "Copy or move", description: "Copy or move files into a folder, sorted into subfolders if you like",
        category: .output,
        inputs: [Port(id: "files", type: .any, label: "Files", list: true),
                 Port(id: "a", type: .any, label: "a", list: true, optional: true)],
        defaults: ["mode": "copy", "subfolder": "", "auto": false], noMap: true, width: 400, writes: true
    ) { run in
        guard run.params["auto"]?.bool == true, run.params["mode"]?.string != "move", !run.context.samples,
              let folder = run.params["folder"]?.string, !folder.isEmpty
        else { return [:] }
        let plan = copyPlan(run.inputs, run.params)
        guard run.context.mayChange(plan.targets) else {
            run.context.note = "Run the flow to copy"
            return [:]
        }
        try FileOps.apply(plan.files, to: plan.targets, .copy)
        return [:]
    }

    /// Where Copy or move puts each file: the folder, then the subfolder
    /// pattern, which may use `{{a}}` to sort by a value from another step.
    static func copyPlan(_ inputs: [String: Value], _ params: Params) -> (files: [URL], targets: [URL]) {
        let items = inputs["files"]?.items ?? []
        let a = inputs["a"]?.items ?? []
        var files: [URL] = [], subs: [Value?] = []
        for (i, item) in items.enumerated() {
            guard let url = item?.fileURL else { continue }
            files.append(url)
            subs.append(i < a.count ? a[i] : nil)
        }
        let folder = SaveTo.resolve(params["folder"]?.string ?? "")
        let sub = params["subfolder"]?.string ?? ""
        let targets = files.enumerated().map { i, url -> URL in
            let name = FileOps.fill(sub, url: url, a: subs[i])
            return (name.isEmpty ? folder : folder.appending(path: name)).appending(path: url.lastPathComponent)
        }
        return (files, targets)
    }
}
