import Foundation

/// Putting what set a run off into the flow it runs: the files, the
/// clipboard, or what a call left, and where the run is saved.
extension TriggerCenter {
    /// The first step a run can fill: a trigger step, or an input that opens files.
    nonisolated static func input(of graph: Graph) -> Node? {
        graph.ordered.first { TriggerSteps.isTrigger($0.type) || InputKind($0.type) != nil }
    }

    /// The steps that record, and take what a recording left.
    nonisolated static func records(_ node: Node) -> Bool {
        ["record", "call"].contains(node.type) || (node.type == "shortcut" && (node.params["takes"]?.string ?? "voice") == "voice")
    }

    nonisolated static func fill(_ graph: inout Graph, with files: [URL]) throws {
        guard let input = input(of: graph), let i = graph.nodes.firstIndex(where: { $0.id == input.id }) else {
            throw StepError("This flow has no step to put the files in")
        }
        let paths = files.map { JSON.string(Samples.path(for: $0)) }
        if ["watch", "shortcut"].contains(input.type) {
            graph.nodes[i].params["files"] = .array(paths)
            return
        }
        switch InputKind(input.type) {
        case .photos?:
            graph.nodes[i].params["samples"] = .array([])
            graph.nodes[i].params["files"] = .array(paths)
        case .photo?, .audio?:
            graph.nodes[i].params["sample"] = nil
            graph.nodes[i].params["file"] = paths[0]
        case .text?:
            graph.nodes[i].params["text"] = .string((try? String(contentsOf: files[0], encoding: .utf8)) ?? "")
        case nil:
            throw StepError("This flow has no step to put the files in")
        }
    }

    /// What was on the clipboard, into a shortcut step that takes it.
    nonisolated static func fill(_ graph: inout Graph, with clipboard: Clipboard) {
        guard let input = input(of: graph), input.type == "shortcut", let i = graph.nodes.firstIndex(where: { $0.id == input.id }) else { return }
        graph.nodes[i].params["text"] = clipboard.text.map { .string($0) } ?? .null
        graph.nodes[i].params["files"] = .array(clipboard.files.map { .string(Samples.path(for: $0)) })
    }

    /// Puts what a call left into the flow: the words and the recording into
    /// its Record step, or the recording into the step that opens audio.
    nonisolated static func fill(_ graph: inout Graph, with take: Take) throws {
        guard let input = input(of: graph), let i = graph.nodes.firstIndex(where: { $0.id == input.id }) else {
            throw StepError("This flow has no step to put the call in")
        }
        if records(input) {
            for (key, value) in Recording.params(take) { graph.nodes[i].params[key] = value == .null ? nil : value }
        } else if let audio = take.audio {
            try fill(&graph, with: [audio])
        } else {
            throw StepError("This flow needs the recording, and it wasn't kept")
        }
    }

    /// Where a run is saved, by its flow's title and the time. Runs that
    /// start in the same second get a number, so none writes over another's
    /// file or the thumbnail next to it.
    static func runFile(_ title: String, in folder: URL = Library.folder("Runs")) -> URL {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: ".")
        let name = "\(title) \(stamp)".replacingOccurrences(of: "/", with: "-")
        var file = folder.appending(path: name).appendingPathExtension("flow")
        var n = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = folder.appending(path: "\(name) \(n)").appendingPathExtension("flow")
            n += 1
        }
        return file
    }
}
