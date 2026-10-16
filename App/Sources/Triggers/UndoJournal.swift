import Foundation
import UniformTypeIdentifiers

/// One thing a run did to a file, kept so it can be undone: a file moved or
/// renamed, a copy made, or a new file written.
struct FileChange: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case moved, copied, written }

    let kind: Kind
    /// Where a moved file was before.
    var from: String?
    /// Where the file is now.
    let to: String
    /// The file as the run left it, so undo never removes a file someone has
    /// since changed.
    var size: Int?
    var modified: Date?

    var url: URL { URL(filePath: to) }
}

/// What the steps of one run did to files. Set for a run with `$current`,
/// which the engine's tasks inherit, so a step records into the run that
/// started it.
final class FileJournal: @unchecked Sendable {
    @TaskLocal static var current: FileJournal?

    private let lock = NSLock()
    private var list: [FileChange] = []

    var changes: [FileChange] { lock.withLock { list } }

    static func moved(_ from: URL, to: URL) {
        current?.add(FileChange(kind: .moved, from: from.path(percentEncoded: false), to: to.path(percentEncoded: false)))
    }

    static func copied(to url: URL) { current?.add(stamped(.copied, url)) }

    /// A file written where none was before. Replacing a file is not undone,
    /// since the old one is gone.
    static func written(_ url: URL, new: Bool) {
        guard new else { return }
        current?.add(stamped(.written, url))
    }

    private static func stamped(_ kind: FileChange.Kind, _ url: URL) -> FileChange {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return FileChange(kind: kind, to: url.path(percentEncoded: false), size: values?.fileSize, modified: values?.contentModificationDate)
    }

    private func add(_ change: FileChange) {
        lock.withLock { list.append(change) }
    }
}

extension [FileChange] {
    /// The files the run left, in order, for opening its result.
    var results: [URL] {
        var seen = Set<String>()
        return compactMap { seen.insert($0.to).inserted ? $0.url : nil }
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    /// What the run did, in a few words: "Renamed 3 screenshots", "Copied 2
    /// photos to Receipts", "Saved the note to Meeting notes".
    var sentence: String? {
        guard let first else { return nil }
        let kinds = Set(map(\.kind))
        guard kinds.count == 1 else { return count == 1 ? nil : "Changed \(FileNoun.of(self).count(count))" }
        let folder = first.url.deletingLastPathComponent().lastPathComponent
        let noun = FileNoun.of(self)
        switch first.kind {
        case .moved:
            let inPlace = allSatisfy { $0.from.map { URL(filePath: $0).deletingLastPathComponent().path } == $0.url.deletingLastPathComponent().path }
            return inPlace ? "Renamed \(noun.count(count))" : "Moved \(noun.count(count)) to \(folder)"
        case .copied:
            return "Copied \(noun.count(count)) to \(folder)"
        case .written:
            return count == 1 ? "Saved \(first.url.deletingPathExtension().lastPathComponent) to \(folder)" : "Saved \(noun.count(count)) to \(folder)"
        }
    }
}

/// What to call files: screenshots, photos, recordings, notes, or files.
struct FileNoun {
    let one: String
    let many: String

    func count(_ n: Int) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }

    static func of(_ changes: [FileChange]) -> FileNoun {
        of(changes.map(\.url), named: changes.map { URL(filePath: $0.from ?? $0.to).lastPathComponent })
    }

    static func of(_ urls: [URL], named names: [String]? = nil) -> FileNoun {
        let names = names ?? urls.map(\.lastPathComponent)
        if names.allSatisfy({ $0.hasPrefix("Screenshot") || $0.hasPrefix("Screen Shot") }) { return FileNoun(one: "screenshot", many: "screenshots") }
        let types = urls.compactMap { UTType(filenameExtension: $0.pathExtension) }
        if types.count == urls.count {
            if types.allSatisfy({ $0.conforms(to: .image) }) { return FileNoun(one: "photo", many: "photos") }
            if types.allSatisfy({ $0.conforms(to: .audio) }) { return FileNoun(one: "recording", many: "recordings") }
            if types.allSatisfy({ $0.conforms(to: .text) }) { return FileNoun(one: "note", many: "notes") }
        }
        return FileNoun(one: "file", many: "files")
    }
}

/// Puts back what a run did to files, newest change first. A file someone
/// has since moved, changed, or replaced is left as it is.
enum Undo {
    struct Outcome: Equatable, Sendable {
        var undone = 0
        var kept = 0
        /// Names files got back, so a folder trigger doesn't take them as new.
        var restored: [URL] = []

        var sentence: String {
            switch (undone, kept) {
            case (_, 0): "Put everything back"
            case (0, _): kept == 1 ? "Left 1 file as it is, since it has changed" : "Left \(kept) files as they are, since they have changed"
            default: "Put \(undone) back. Left \(kept) as \(kept == 1 ? "it is" : "they are"), since \(kept == 1 ? "it has" : "they have") changed"
            }
        }
    }

    /// `remove` takes away a copy or a written file; the Trash by default.
    static func revert(_ changes: [FileChange], remove: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> Outcome {
        let fm = FileManager.default
        var outcome = Outcome()
        for change in changes.reversed() {
            let now = change.url
            let exists = fm.fileExists(atPath: now.path(percentEncoded: false))
            switch change.kind {
            case .moved:
                guard let from = change.from.map({ URL(filePath: $0) }), exists, (try? moveBack(now, to: from)) != nil else {
                    outcome.kept += 1
                    continue
                }
                outcome.undone += 1
                outcome.restored.append(from)
            case .copied, .written:
                guard exists, unchanged(now, change), (try? remove(now)) != nil else {
                    outcome.kept += 1
                    continue
                }
                outcome.undone += 1
            }
        }
        return outcome
    }

    /// Moves a file back to its old name, if that name is free. A name that
    /// differs only in case goes through a temporary name.
    private static func moveBack(_ now: URL, to old: URL) throws {
        let fm = FileManager.default
        if now.path.lowercased() == old.path.lowercased() {
            let temporary = now.deletingLastPathComponent().appending(path: ".\(UUID().uuidString)-\(now.lastPathComponent)")
            try fm.moveItem(at: now, to: temporary)
            try fm.moveItem(at: temporary, to: old)
            return
        }
        guard !fm.fileExists(atPath: old.path(percentEncoded: false)) else { throw CocoaError(.fileWriteFileExists) }
        try fm.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: now, to: old)
    }

    private static func unchanged(_ url: URL, _ change: FileChange) -> Bool {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return values?.fileSize == change.size && values?.contentModificationDate == change.modified
    }
}
