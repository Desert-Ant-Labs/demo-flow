import AppKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// Values leaving the app: as files for Quick Look, drag and drop, Save, and
/// the share sheet, or as text and pictures on the clipboard.
enum Exports {
    /// This launch's temporary files. Older launches' folders are removed.
    static let folder: URL = {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory
        let mine = "Flow-\(ProcessInfo.processInfo.processIdentifier)"
        let dayAgo = Date().addingTimeInterval(-86_400)
        for old in (try? fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where old.lastPathComponent.hasPrefix("Flow-") && old.lastPathComponent != mine
            && ((try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture) < dayAgo {
            try? fm.removeItem(at: old)
        }
        let dir = temp.appending(path: mine)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Files already written for a photo or a recording, held only as long as
    /// the value itself, so a later value never gets an earlier one's file.
    @MainActor private static let written = NSMapTable<AnyObject, NSURL>(
        keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)

    /// The photo's own file when it has one, otherwise a PNG of it.
    @MainActor static func file(for photo: Photo) -> URL {
        if let file = photo.file { return file }
        if let url = written.object(forKey: photo) { return url as URL }
        let url = writePNG(photo)
        written.setObject(url as NSURL, forKey: photo)
        return url
    }

    /// The same, with the PNG made off the main actor: a full-size picture
    /// takes long enough to encode to stall a drag or a save.
    @MainActor static func export(_ photo: Photo) async -> URL {
        if let file = photo.file { return file }
        if let url = written.object(forKey: photo) { return url as URL }
        let url = await Task.detached { writePNG(photo) }.value
        // Another drag of the same photo may have finished first.
        if let url = written.object(forKey: photo) { return url as URL }
        written.setObject(url as NSURL, forKey: photo)
        return url
    }

    private static func writePNG(_ photo: Photo) -> URL {
        let url = unique(photo.name.hasSuffix(".png") ? photo.name : photo.name + ".png")
        try? Media.png(photo.image).write(to: url)
        return url
    }

    @MainActor static func file(for clip: AudioClip, name: String) -> URL {
        if let url = written.object(forKey: clip) { return url as URL }
        let url = unique("\(name).wav")
        try? Media.wav(clip).write(to: url)
        written.setObject(url as NSURL, forKey: clip)
        return url
    }

    static func file(text: String, name: String) -> URL {
        let url = unique(name)
        try? Data(text.utf8).write(to: url)
        return url
    }

    /// A fresh folder per file keeps its name as it should be.
    private static func unique(_ name: String) -> URL {
        let dir = folder.appending(path: UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: name)
    }

    static func slug(_ s: String) -> String {
        let out = s.lowercased().replacing(#/[^a-z0-9]+/#, with: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return out.isEmpty ? "result" : out
    }

    private static func isRecords(_ xs: [Value]) -> Bool {
        !xs.isEmpty && xs.allSatisfy(\.isRecord)
    }

    /// Records as rows under one header, in the order their fields first appear.
    static func table(_ rows: [Value], separator: Character) -> String {
        CSV.text(rows, separator: separator)
    }

    /// Plain text for the clipboard and the share sheet. A table comes out
    /// tab separated, which pastes into a spreadsheet as columns.
    static func plainText(_ value: Value) -> String {
        switch value {
        case .list, .stream:
            let xs = value.present
            if isRecords(xs) { return table(xs, separator: "\t") }
            return xs.map(\.asText).joined(separator: "\n")
        case .record: return value.jsonText()
        default: return value.asText
        }
    }

    /// How a result can be saved: text as .txt or .md, a table as .csv or
    /// .json, photos as their files, audio as .wav.
    @MainActor
    static func saveOptions(_ value: Value?, title: String) -> [SaveOption] {
        guard let value else { return [] }
        let name = slug(title)
        switch value {
        case .audio(let clip):
            return [SaveOption(label: "Audio (.wav)") { [file(for: clip, name: name)] }]
        case .image(let photo):
            return [SaveOption(label: "Photo") { [await export(photo)] }]
        default: break
        }
        let xs = value.present
        if case .list = value, xs.isEmpty { return [] }
        let k = kind(of: value)
        if k == .gallery {
            return [SaveOption(label: xs.count == 1 ? "1 photo" : "\(xs.count) photos") {
                var files: [URL] = []
                for photo in xs.compactMap(\.photo) { files.append(await export(photo)) }
                return files
            }]
        }
        let text = plainText(value)
        var options: [SaveOption] = []
        if isRecords(xs), value.isList { options.append(SaveOption(label: "Spreadsheet (.csv)") { [file(text: table(xs, separator: ","), name: "\(name).csv")] }) }
        if [.markdown, .document, .text].contains(k) { options.append(SaveOption(label: "Markdown (.md)") { [file(text: text, name: "\(name).md")] }) }
        options.append(SaveOption(label: "Text (.txt)") { [file(text: text, name: "\(name).txt")] })
        if value.isList || value.isRecord { options.append(SaveOption(label: "Data (.json)") { [file(text: value.jsonText(), name: "\(name).json")] }) }
        return options
    }

    /// Copies text, or a single photo as a picture.
    @MainActor
    static func copy(_ value: Value) {
        let board = NSPasteboard.general
        board.clearContents()
        if let photo = value.photo {
            board.writeObjects([NSImage(cgImage: photo.image, size: .zero)])
            return
        }
        board.setString(plainText(value), forType: .string)
    }

    /// Saves files where the person picks: one file through a save panel,
    /// several into a folder they choose, next to what is there.
    @MainActor
    static func save(_ files: [URL], window: NSWindow?) {
        guard !files.isEmpty else { return }
        let report = { (error: Error) in
            if let window { NSAlert(error: error).beginSheetModal(for: window) } else { NSAlert(error: error).runModal() }
        }
        if files.count == 1 {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = files[0].lastPathComponent
            panel.canCreateDirectories = true
            let done = { (r: NSApplication.ModalResponse) in
                guard r == .OK, let url = panel.url else { return }
                do { try put(files[0], at: url) } catch { report(error) }
            }
            if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save \(files.count) Files Here"
        let done = { (r: NSApplication.ModalResponse) in
            guard r == .OK, let dir = panel.url else { return }
            do {
                for f in files where !same(f.deletingLastPathComponent(), dir) {
                    try FileManager.default.copyItem(at: f, to: free(f.lastPathComponent, in: dir))
                }
            } catch { report(error) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }

    /// Puts a copy of `source` at `url`, replacing what is there only once the
    /// copy is whole. Saving a file over itself leaves it as it is.
    private static func put(_ source: URL, at url: URL) throws {
        let fm = FileManager.default
        if same(source, url) { return }
        guard fm.fileExists(atPath: url.path) else { return try fm.copyItem(at: source, to: url) }
        let scratch = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? fm.removeItem(at: scratch) }
        let copy = scratch.appending(path: url.lastPathComponent)
        try fm.copyItem(at: source, to: copy)
        _ = try fm.replaceItemAt(url, withItemAt: copy)
    }

    private static func same(_ a: URL, _ b: URL) -> Bool {
        let key: (URL) -> NSObject? = { (try? $0.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject }
        if let x = key(a), let y = key(b) { return x.isEqual(y) }
        return a.standardizedFileURL.resolvingSymlinksInPath() == b.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// `name` in `dir`, or "name 2", "name 3" when that is taken.
    static func free(_ name: String, in dir: URL) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var url = dir.appending(path: name), n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }
}

/// A photo dragged out of a card.
struct PhotoTransfer: Transferable {
    let photo: Photo

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .image) { item in
            SentTransferredFile(await Exports.export(item.photo))
        }
    }
}

/// Opens Quick Look on a photo, with the photos around it to page through.
struct OpenQuickLook {
    var action: @MainActor ([Photo], Photo) -> Void = { _, _ in }
    @MainActor func callAsFunction(_ all: [Photo], _ photo: Photo) { action(all, photo) }
}

extension EnvironmentValues {
    @Entry var openQuickLook = OpenQuickLook()
}

/// One way to save a result, with the files it makes when picked.
struct SaveOption: Identifiable {
    let label: String
    let files: @MainActor () async -> [URL]
    var id: String { label }
}

extension Value {
    var isList: Bool {
        switch self {
        case .list, .stream: true
        default: false
        }
    }

    var isRecord: Bool {
        if case .record = self { true } else { false }
    }
}

/// The system share menu, for files or text. The items are made only when
/// the menu opens, so a card does not write files it may never share.
struct ShareButton: NSViewRepresentable {
    let items: @MainActor () async -> [Any]

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Share", image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)!,
                              target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.bezelStyle = .push
        button.controlSize = .small
        button.imagePosition = .imageLeading
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.items = items
    }

    func makeCoordinator() -> Coordinator { Coordinator(items: items) }

    @MainActor
    final class Coordinator: NSObject {
        var items: @MainActor () async -> [Any]
        init(items: @escaping @MainActor () async -> [Any]) { self.items = items }

        @objc func share(_ sender: NSButton) {
            Task {
                let picker = NSSharingServicePicker(items: await items())
                picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            }
        }
    }
}
