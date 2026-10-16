import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Files dropped on a flow's window and whatever is pasted into it.
@MainActor
struct FlowInbox {
    @Binding var graph: Graph
    let session: FlowSession
    let actions: FlowActions
    let newDocument: NewDocumentAction

    /// The steps a dropped file can go into.
    static let droppable: Set<String> = ["photos", "image", "audio", "record", "text", "files"]

    private static func isFlow(_ url: URL) -> Bool { ["flow", "yml", "yaml"].contains(url.pathExtension.lowercased()) }

    /// Dropped or pasted files, by what they hold.
    private struct Sorted {
        var images: [URL] = []
        var audio: [URL] = []
        var texts: [URL] = []

        init(_ urls: [URL]) {
            for u in urls {
                let type = UTType(filenameExtension: u.pathExtension) ?? .data
                if type.conforms(to: .image) { images.append(u) }
                else if type.conforms(to: .audiovisualContent) { audio.append(u) }
                else if type.conforms(to: .text) || ["md", "txt", "csv"].contains(u.pathExtension.lowercased()) { texts.append(u) }
            }
        }
    }

    /// Where files dropped on the window go: the selected input, or else the
    /// first one in the flow.
    var dropCandidate: Node? {
        let inputs = graph.ordered.filter { Self.droppable.contains($0.type) }
        if session.selection.count == 1, let n = inputs.first(where: { session.selection.contains($0.id) }) { return n }
        return inputs.first
    }

    func targeted(_ on: Bool) {
        session.dropTarget = on ? dropCandidate?.id : nil
        session.droppingOnEmpty = on && graph.nodes.isEmpty
    }

    /// Files dropped on the window replace what an input holds: the one that
    /// lit up when they can go there, or else the first that takes them. Only
    /// when none does do they start a step of their own.
    func drop(_ urls: [URL], at: CGPoint?) {
        session.dropTarget = nil
        session.droppingOnEmpty = false
        if urls.contains(where: Self.isFlow) { return add(urls, at: at) }
        let candidates = [dropCandidate].compactMap { $0 } + graph.ordered.filter { Self.droppable.contains($0.type) }
        for node in candidates {
            guard let (patch, note) = replacement(for: node, urls) else { continue }
            actions.set(node.id, patch)
            session.show(node.id)
            session.notify(note)
            return
        }
        add(urls, at: at)
    }

    /// What an input becomes with these files in it, or nil when it takes
    /// none of them.
    private func replacement(for node: Node, _ urls: [URL]) -> (Params, String)? {
        let files = Sorted(urls)
        let path = { (u: URL) in JSON.string(Samples.path(for: u)) }
        switch node.type {
        case "photos" where !files.images.isEmpty:
            return (["samples": .array([]), "files": .array(files.images.map(path))],
                    files.images.count == 1 ? "Using your photo" : "Using your \(files.images.count) photos")
        case "image" where !files.images.isEmpty:
            return (["file": path(files.images[0]), "sample": .null], "Using your photo")
        case "audio" where !files.audio.isEmpty, "record" where !files.audio.isEmpty:
            return (["file": path(files.audio[0]), "sample": .null], "Using your recording")
        case "text":
            guard let t = files.texts.first, let text = try? String(contentsOf: t, encoding: .utf8) else { return nil }
            return (["text": .string(text)], "Using your text")
        case "files":
            let folder = { (u: URL) in (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            return (["files": .array(urls.filter { !folder($0) }.map(path)), "folders": .array(urls.filter(folder).map(path))],
                    "Using your files")
        default:
            return nil
        }
    }

    /// Anything dropped or pasted becomes a start step, selected so Add Next
    /// Step builds on it. A flow file opens in its own window.
    func add(_ urls: [URL], at: CGPoint?) {
        if let flow = urls.first(where: Self.isFlow) {
            NSDocumentController.shared.openDocument(withContentsOf: flow, display: true) { _, _, _ in }
            return
        }
        let files = Sorted(urls)
        if files.images.count == 1 { addStart("image", ["file": .string(Samples.path(for: files.images[0]))], at: at) }
        if files.images.count > 1 {
            addStart("photos", ["samples": .array([]), "files": .array(files.images.map { .string(Samples.path(for: $0)) })], at: at)
        }
        for a in files.audio { addStart("audio", ["file": .string(Samples.path(for: a))], at: at) }
        for t in files.texts {
            if let text = try? String(contentsOf: t, encoding: .utf8) { addStart("text", ["text": .string(text)], at: at) }
        }
        let added = (files.images.isEmpty ? 0 : 1) + files.audio.count + files.texts.count
        session.notify(added > 0 ? "Added. Use Add Next Step to work with it." : "Drop photos, audio, or a text file")
    }

    private func addStart(_ type: String, _ params: Params, at: CGPoint?) {
        let id = newNodeID(type)
        let left = (graph.nodes.map { session.position($0, arranged: graph.meta.arranged).x }.min() ?? 0) - 360
        let position = at ?? session.freeSpot(min(0, left), 0, in: graph)
        var p = (Steps.byType[type]?.defaults ?? [:]).merging(params) { $1 }
        p["sample"] = nil
        graph.nodes.append(Node(id: id, type: type, position: position, params: p))
        session.keepPlace(of: id, in: graph)
        session.show(id)
    }

    /// Reads the pasteboard itself, so a pasted file, image, flow, link, or
    /// text each lands as it should.
    func paste() {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            add(urls, at: nil)
            return
        }
        if let image = NSImage(pasteboard: board), board.string(forType: .string) == nil,
           let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            let url = Library.folder("Pasted").appending(path: "Pasted \(Date().timeIntervalSince1970).png")
            try? png.write(to: url)
            add([url], at: nil)
            return
        }
        guard let text = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        if FlowFile.looksLikeFlow(text), let g = try? FlowFile.read(text) {
            newDocument(FlowDocument(graph: g))
        } else if let code = FlowLink.code(in: text) {
            if let g = try? FlowLink.graph(from: code) { newDocument(FlowDocument(graph: g)) } else { session.notify("That link could not be opened") }
        } else {
            let lines = text.components(separatedBy: "\n").count
            addStart("text", ["text": .string(text), "rows": .number(Double(min(10, max(3, lines))))], at: nil)
            session.notify("Added your text. Use Add Next Step to work with it.")
        }
    }
}
