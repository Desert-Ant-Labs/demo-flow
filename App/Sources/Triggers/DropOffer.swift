import Foundation

/// Files dropped on the floater, and the flows that can take them, the one
/// chosen last for that kind of file first.
struct DropOffer: Identifiable {
    struct Choice: Identifiable, Hashable {
        let ref: Trigger.FlowRef
        let title: String
        let models: [ModelID]
        var id: Trigger.FlowRef { ref }
    }

    let id = UUID()
    let files: [URL]
    let choices: [Choice]

    var what: String {
        files.count == 1 ? files[0].lastPathComponent : FileNoun.of(files).count(files.count)
    }

    static let shown = 5

    /// The flows that take every one of `files`: yours first, newest first,
    /// then the templates.
    static func make(_ files: [URL], mine: [SavedFlow]) -> DropOffer {
        let fits = { (kinds: [InputKind]) in files.allSatisfy { file in kinds.contains { $0.takes(file) } } }
        var choices = mine.filter { fits($0.takes) }.map {
            Choice(ref: .file(path: $0.url.path), title: $0.title, models: $0.models)
        }
        choices += Example.all.filter { fits(templateTakes[$0.id] ?? []) }.map {
            Choice(ref: .template(id: $0.id), title: $0.title, models: $0.models)
        }
        if let last = last(for: files), let i = choices.firstIndex(where: { $0.ref == last }) {
            choices.insert(choices.remove(at: i), at: 0)
        }
        return DropOffer(files: files, choices: Array(choices.prefix(shown)))
    }

    /// Remembers the flow chosen for this kind of file.
    func chose(_ choice: Choice) {
        guard let key = Self.key(for: files), let data = try? JSONEncoder().encode(choice.ref) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func last(for files: [URL]) -> Trigger.FlowRef? {
        guard let key = key(for: files), let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Trigger.FlowRef.self, from: data)
    }

    private static func key(for files: [URL]) -> String? {
        let kinds: [(String, InputKind)] = [("photo", .photo), ("audio", .audio), ("text", .text)]
        return kinds.first { _, kind in files.allSatisfy(kind.takes) }.map { "floater.drop.\($0.0)" }
    }

    /// What each template can take from files, read once.
    private static let templateTakes: [String: [InputKind]] = Dictionary(
        uniqueKeysWithValues: Example.all.map { ($0.id, $0.graph.takes) })
}
