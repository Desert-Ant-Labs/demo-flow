import Foundation
import Yams

/// The examples in the library: the YAML files in Resources/Examples, the same
/// files the web app ships. The file name sets the order and the id:
/// 05-receipts.yml is the receipts example, fifth in the library.
struct Example: Identifiable, Sendable {
    let id: String
    let title: String
    let blurb: String
    let models: [ModelID]
    let text: String
    let group: Group
    /// The type of its first input step: a trigger step means it runs on its own once turned on.
    var start: String?

    var automatic: Bool { start.map(TriggerSteps.isTrigger) ?? false }

    /// What an example starts from, which is how the library sorts them.
    enum Group: String, CaseIterable, Sendable {
        case photos, audio, text, drawings

        var label: String {
            switch self {
            case .photos: "Photos"
            case .audio: "Audio and meetings"
            case .text: "Text"
            case .drawings: "Drawings"
            }
        }

        init(start type: String?) {
            switch type {
            case "audio", "record", "call", "shortcut": self = .audio
            case "text", "textlist": self = .text
            case "sketch", "whiteboard": self = .drawings
            default: self = .photos
            }
        }
    }

    var graph: Graph {
        var g = (try? FlowFile.read(text)) ?? Graph()
        g.meta.arranged = false
        return g
    }

    static let all: [Example] = {
        guard let dir = Bundle.main.resourceURL?.appending(path: "Examples"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "yml" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap(load)
    }()

    private static func load(_ url: URL) -> Example? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let doc = try? Yams.load(yaml: text) as? [String: Any],
              let steps = doc["steps"] as? [[String: Any]]
        else { return nil }
        let id = url.deletingPathExtension().lastPathComponent.replacing(#/^\d+-/#, with: "")
        let models = (try? FlowFile.read(text).models) ?? []
        let start = steps.lazy.compactMap { $0["type"] as? String }.first { Steps.byType[$0]?.category == .input }
        // New files can be anything; what the flow does with them says which.
        let group = start == "watch" && text.contains("in.audio") ? Group.audio : Group(start: start)
        return Example(id: id, title: doc["title"] as? String ?? id,
                       blurb: doc["summary"] as? String ?? doc["description"] as? String ?? "",
                       models: models, text: text, group: group, start: start)
    }
}
