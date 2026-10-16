import Foundation

/// Turning on a template that starts with a trigger step: a copy of it is
/// saved with the user's flows, its folder made ready, and turned on. Turned
/// on again, the same copy is used.
@MainActor
enum AutomaticTemplates {
    @discardableResult
    static func turnOn(_ example: Example) throws -> URL {
        let center = TriggerCenter.shared
        if let entry = center.entry(template: example.id) {
            center.setOn(true, path: entry.path)
            return URL(filePath: entry.path)
        }
        var graph = example.graph
        if let i = graph.nodes.firstIndex(where: { $0.type == "watch" }) {
            let folder = example.id == "name-screenshots"
                ? screenshotFolder
                : URL(filePath: ((graph.nodes[i].params["folder"]?.string ?? "") as NSString).expandingTildeInPath)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            graph.nodes[i].params["folder"] = .string(Samples.path(for: folder))
        }
        let file = SaveTo.flowFile(named: example.title)
        try FlowFile.write(graph).write(to: file, atomically: true, encoding: .utf8)
        center.setOn(true, path: file.path, template: example.id)
        return file
    }

    static func turnOff(_ example: Example) {
        guard let entry = TriggerCenter.shared.entry(template: example.id) else { return }
        TriggerCenter.shared.setOn(false, path: entry.path)
    }

    static func isOn(_ example: Example) -> Bool {
        TriggerCenter.shared.entry(template: example.id)?.on ?? false
    }

    /// Where macOS saves screenshots: the folder chosen in the Screenshot app,
    /// or the Desktop.
    static var screenshotFolder: URL {
        let chosen = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        if let chosen, !chosen.isEmpty {
            let url = URL(filePath: (chosen as NSString).expandingTildeInPath, directoryHint: .isDirectory)
            if (try? url.checkResourceIsReachable()) == true { return url }
        }
        return URL.desktopDirectory
    }
}
