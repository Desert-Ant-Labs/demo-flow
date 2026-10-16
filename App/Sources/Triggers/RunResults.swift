import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a run made: opening it, showing it in the Finder, and saying it in
/// a line with a small picture.
extension TriggerCenter {
    /// Opens what a run made: the one file it wrote, as a meeting's note, or
    /// the files it touched in the Finder, or the run itself.
    func openResult(_ record: RunRecord) {
        open(result: record.result, run: record.file)
    }

    func openResult(_ run: FlowRun) {
        open(result: run.result, run: run.file?.path ?? "")
    }

    private func open(result: [URL], run: String) {
        switch result.count {
        case 0: open(run)
        case 1: NSWorkspace.shared.open(result[0])
        default: NSWorkspace.shared.activateFileViewerSelecting(result)
        }
    }

    func open(_ path: String) {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return NSSound.beep() }
        NSApp.activate()
        NSDocumentController.shared.openDocument(withContentsOf: URL(filePath: path), display: true) { _, _, _ in }
    }

    /// Shows what a run worked on in the Finder: the new files, or the call's recording.
    func reveal(_ run: FlowRun) {
        let urls = run.files.isEmpty ? run.file.map { [$0] } ?? [] : run.files
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// What the flow ended with, in a line for a notification.
    static func summary(_ graph: Graph, _ engine: Engine) -> String {
        for node in graph.ordered.reversed() where node.def?.category == .output {
            if let value = engine.state(node.id).inputs.values.first, let line = line(value) { return line }
        }
        return "Finished with nothing to show."
    }

    private static func line(_ value: Value) -> String? {
        switch value {
        case .list(let l), .stream(let l):
            let present = l.compactMap { $0 }
            if present.isEmpty { return "Nothing matched." }
            if case .image = present[0] { return present.count == 1 ? "1 photo" : "\(present.count) photos" }
            if case .record = present[0] { return present.count == 1 ? "1 row" : "\(present.count) rows" }
            return String(value.asText.prefix(160))
        case .image: return "A photo"
        case .audio: return "A recording"
        default:
            let text = value.asText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : String(text.prefix(160))
        }
    }

    static func firstPhoto(_ graph: Graph, _ engine: Engine) -> Photo? {
        func photo(in value: Value?) -> Photo? {
            switch value {
            case .image(let p): p
            case .list(let l), .stream(let l): l.lazy.compactMap { photo(in: $0) }.first
            default: nil
            }
        }
        return graph.ordered.reversed().filter { $0.def?.category == .output }
            .lazy.compactMap { node in engine.state(node.id).inputs.values.lazy.compactMap { photo(in: $0) }.first }.first
    }

    /// A small JPEG next to the saved run, for notifications and the recent list.
    static func thumbnail(_ photo: Photo, next file: URL) -> URL? {
        let url = file.deletingPathExtension().appendingPathExtension("jpg")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, photo.thumb, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? url : nil
    }
}
