import Foundation

/// Where flows write what they make: one folder, set in Settings, with a
/// folder inside it per kind of result, like Meeting notes or Receipts.
enum SaveTo {
    static let key = "saveToFolder"

    static var root: URL {
        if let set = UserDefaults.standard.string(forKey: key), !set.isEmpty {
            return URL(filePath: (set as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        }
        return URL.documentsDirectory.appending(path: "Desert Ant Flow", directoryHint: .isDirectory)
    }

    /// A step's folder setting as a place: a path as written, or a bare name,
    /// as "Meeting notes", inside Save to.
    static func resolve(_ setting: String) -> URL {
        let trimmed = setting.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix("/samples/") {
            return Samples.url(trimmed)
        }
        return root.appending(path: trimmed, directoryHint: .isDirectory)
    }

    /// Where a Save to folder step writes: the folder it names, or beside the
    /// file the flow runs on.
    static func folder(_ setting: String?, beside source: URL?) -> URL? {
        guard let setting, !setting.isEmpty else { return source?.deletingLastPathComponent() }
        return resolve(setting)
    }

    /// A file name from a Save to folder step's pattern: `{{a}}` from the
    /// value given, `{{name}}` from the file the flow runs on, the date and
    /// time filled in, and no slashes or colons, which a name cannot hold.
    static func fileName(_ pattern: String, a: Value?, source: URL?) -> String {
        Placeholders.fill(pattern) {
            switch $0 {
            case "a": a.asText
            case "name": source?.deletingPathExtension().lastPathComponent ?? "result"
            default: nil
            }
        }
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A new flow file in Save to's Flows folder, numbered if the name is taken.
    static func flowFile(named name: String) -> URL {
        let folder = root.appending(path: "Flows", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var url = folder.appending(path: base + ".flow"), n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(base) \(n).flow")
            n += 1
        }
        return url
    }
}
