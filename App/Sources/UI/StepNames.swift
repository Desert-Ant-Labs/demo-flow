import Foundation

/// What each step is called on its card and in the menus that name it.
///
/// A step goes by the name someone gave it, kept in its `label` setting. Until
/// then it goes by its model or its kind, so a flow reads "Eye" and "Template".
/// Two steps of the same kind would read alike, as two Galleries do, so those
/// go by their ids where a person wrote them ("portraits" reads "Portraits"),
/// and otherwise by a number: "Gallery", "Gallery 2".
extension Graph {
    func name(of id: String) -> String {
        names()[id] ?? id
    }

    /// What a step would be called with no name of its own.
    func defaultName(of id: String) -> String {
        names(ignoringLabelOf: id)[id] ?? id
    }

    func names(ignoringLabelOf ignored: String? = nil) -> [String: String] {
        let steps = nodes.filter { $0.type != "note" }
        let kind = { (n: Node) in n.def.map { $0.model?.info.name ?? $0.title } ?? n.type }
        let shared = Dictionary(steps.map { (kind($0), 1) }, uniquingKeysWith: +)
        var names: [String: String] = [:]
        var seen: [String: Int] = [:]
        for n in steps {
            if n.id != ignored, let given = n.params["label"]?.string?.trimmingCharacters(in: .whitespaces), !given.isEmpty {
                names[n.id] = given
                continue
            }
            let base = kind(n)
            var name = base
            if shared[base, default: 0] > 1, let readable = Self.readable(n.id, type: n.type), readable.lowercased() != base.lowercased() {
                name = readable
            }
            let count = seen[name, default: 0] + 1
            seen[name] = count
            names[n.id] = count > 1 ? "\(name) \(count)" : name
        }
        return names
    }

    /// A step id written by hand, as words: "portraits" is "Portraits" and
    /// "best_shot" is "Best shot". An id the editor made, "gallery-mf3k2a1",
    /// says nothing, so it gives nil.
    static func readable(_ id: String, type: String) -> String? {
        if id.hasPrefix(type + "-"), id.dropFirst(type.count + 1).allSatisfy({ $0.isNumber || ("a"..."z").contains($0) }) { return nil }
        var words: [String] = []
        var word = ""
        for c in id {
            if c == "-" || c == "_" || c == " " || (c.isUppercase && !word.isEmpty) {
                if !word.isEmpty { words.append(word) }
                word = c.isLetter || c.isNumber ? String(c) : ""
            } else {
                word.append(c)
            }
        }
        if !word.isEmpty { words.append(word) }
        guard let first = words.first else { return nil }
        return ([first.prefix(1).uppercased() + first.dropFirst().lowercased()] + words.dropFirst().map { $0.lowercased() })
            .joined(separator: " ")
    }
}
