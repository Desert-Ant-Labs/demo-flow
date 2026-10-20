import Foundation
import NaturalLanguage

/// The pieces a text can be split into.
enum Segment {
    case lines, sentences, paragraphs

    func split(_ text: String) -> [String] {
        let trimmed = { (s: Substring) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let pieces: [String]
        switch self {
        case .lines:
            pieces = text.split(whereSeparator: \.isNewline).map(trimmed)
        case .paragraphs:
            pieces = text.split(separator: #/\n\s*\n/#).map(trimmed)
        case .sentences:
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = text
            pieces = tokenizer.tokens(for: text.startIndex..<text.endIndex).map { trimmed(text[$0]) }
        }
        return pieces.filter { !$0.isEmpty }
    }
}

/// The conditions Split can test.
enum Condition: String, CaseIterable, Sendable {
    case equals, notEquals, oneOf, contains, above, below, truthy, falsy, empty

    var label: String {
        switch self {
        case .equals: "is"
        case .notEquals: "is not"
        case .oneOf: "is one of"
        case .contains: "contains"
        case .above: "is above"
        case .below: "is below"
        case .truthy: "is yes"
        case .falsy: "is no"
        case .empty: "is empty"
        }
    }

    var unary: Bool { [.truthy, .falsy, .empty].contains(self) }

    func test(_ value: Value?, _ operand: String) -> Bool {
        let text = value.asText
        switch self {
        case .equals: return text.lowercased() == operand.lowercased()
        case .notEquals: return text.lowercased() != operand.lowercased()
        case .oneOf:
            return operand.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }.contains(text.lowercased())
        case .contains: return text.lowercased().contains(operand.lowercased())
        case .above: return (value?.asNumber ?? .nan) > (Double(operand) ?? .nan)
        case .below: return (value?.asNumber ?? .nan) < (Double(operand) ?? .nan)
        case .truthy:
            switch value {
            case nil: return false
            case .bool(let b): return b
            case .number(let n): return n != 0
            case .text(let s): return !s.isEmpty && s != "false"
            default: return true
            }
        case .falsy: return !Condition.truthy.test(value, operand)
        case .empty:
            if case .number(let n) = value, n == 0 { return true }
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

/// What List can do to a list. Some read the number field; the sorts use it to
/// cut the list short.
enum ListOp: String, CaseIterable, Sendable {
    case desc, asc, most, firstN, lastN, item, count, unique, sort, reverse, compact

    var label: String {
        switch self {
        case .desc: "Highest first"
        case .asc: "Lowest first"
        case .most: "Most common"
        case .firstN: "First"
        case .lastN: "Last"
        case .item: "Item number"
        case .count: "Count"
        case .unique: "Unique"
        case .sort: "A to Z"
        case .reverse: "Reverse"
        case .compact: "Remove empty"
        }
    }

    var takesNumber: Bool { [.most, .firstN, .lastN, .item].contains(self) }
    /// Sorts, which keep the whole list unless given a number.
    var keeps: Bool { [.desc, .asc, .sort].contains(self) }

    /// The number a setting of `n` stands for: 0 keeps a sorted list whole
    /// and takes 3 for the rest.
    func count(_ n: Int) -> Int { n > 0 ? n : keeps ? 0 : 3 }

    func run(_ list: [Value?], n: Int, by: [Value?]?) -> Value? {
        let present = list.compactMap { $0 }
        let n = max(0, n)
        let keep = { (l: [Value]) in n > 0 ? Array(l.prefix(n)) : l }
        switch self {
        case .desc: return .list(keep(sorted(list, by: by, ascending: false)))
        case .asc, .sort: return .list(keep(sorted(list, by: by, ascending: true)))
        case .most:
            var counts: [String: (value: Value, count: Int, first: Int)] = [:]
            for (i, v) in present.enumerated() {
                counts[v.asText, default: (v, 0, i)].count += 1
            }
            return .list(counts.values.sorted { ($1.count, $0.first) < ($0.count, $1.first) }.prefix(n).map(\.value))
        case .firstN: return .list(Array(present.prefix(n)))
        case .lastN: return .list(Array(present.suffix(n)))
        case .item: return n >= 1 && n <= present.count ? present[n - 1] : nil
        case .count: return .number(Double(present.count))
        case .unique:
            var seen = Set<String>()
            return .list(present.filter { seen.insert($0.asText).inserted })
        case .reverse: return .list(present.reversed())
        case .compact: return .list(present.filter { !$0.asText.trimmingCharacters(in: .whitespaces).isEmpty })
        }
    }

    private func sorted(_ list: [Value?], by: [Value?]?, ascending: Bool) -> [Value] {
        let pairs = list.enumerated().compactMap { i, v -> (Value, Value?)? in
            guard let v else { return nil }
            return (v, by.map { i < $0.count ? $0[i] : nil } ?? v)
        }
        return pairs.sorted { a, b in
            let order = compare(a.1, b.1)
            return ascending ? order < 0 : order > 0
        }.map(\.0)
    }
}

/// Numbers by value, everything else by its words.
func compare(_ a: Value?, _ b: Value?) -> Int {
    if let x = a?.asNumber, let y = b?.asNumber, x.isFinite, y.isFinite {
        return x < y ? -1 : x > y ? 1 : 0
    }
    switch a.asText.localizedStandardCompare(b.asText) {
    case .orderedAscending: return -1
    case .orderedDescending: return 1
    case .orderedSame: return 0
    }
}

extension Value {
    /// A stream when any item survived, otherwise nothing.
    static func sparse(_ items: [Value?]) -> Value? {
        items.contains { $0 != nil } ? .stream(items) : nil
    }
}

enum LogicSteps {
    static let all: [StepDef] = [ifElse, merge, list, best, template, join]

    static let ifElse = StepDef(
        type: "if", title: "Split", description: "Send each value down one of two paths",
        category: .logic,
        inputs: [Port(id: "value", type: .any, label: "Value"), Port(id: "test", type: .any, label: "Check", optional: true)],
        outputs: [Port(id: "yes", type: .any, label: "If"), Port(id: "no", type: .any, label: "Else")],
        defaults: ["op": "equals", "operand": ""], noMap: true
    ) { run in
        let op = Condition(rawValue: run.params["op"]?.string ?? "") ?? .equals
        let operand = run.params["operand"]?.string ?? ""
        let value = run.inputs["value"]
        let test = run.inputs["test"] ?? value
        if case .stream(let items) = value {
            let pass: [Bool?] = items.enumerated().map { i, v in
                guard v != nil else { return nil }
                if case .stream(let t) = test { return op.test(i < t.count ? t[i] : nil, operand) }
                return op.test(test, operand)
            }
            var out: Outputs = [:]
            out["yes"] = Value.sparse(items.enumerated().map { pass[$0] == true ? $1 : nil })
            out["no"] = Value.sparse(items.enumerated().map { pass[$0] == false ? $1 : nil })
            return out
        }
        guard let value else { return [:] }
        return op.test(test, operand) ? ["yes": value] : ["no": value]
    }

    static let merge = StepDef(
        type: "merge", title: "Merge", description: "Join the If and Else of a Split back together, item by item",
        category: .logic,
        inputs: [Port(id: "a", type: .any, label: "If", optional: true), Port(id: "b", type: .any, label: "Else", optional: true)],
        outputs: [Port(id: "value", type: .any, label: "Value")],
        noMap: true, anyInput: true
    ) { run in
        let a = run.inputs["a"], b = run.inputs["b"]
        func stream(_ v: Value?) -> [Value?]? {
            if case .stream(let l) = v { l } else { nil }
        }
        func item(_ v: Value?, at i: Int) -> Value? {
            guard let l = stream(v) else { return v }
            return i < l.count ? l[i] : nil
        }
        if let n = [stream(a), stream(b)].compactMap({ $0?.count }).max() {
            return ["value": .stream((0..<n).map { item(a, at: $0) ?? item(b, at: $0) })]
        }
        guard let v = a ?? b else { return [:] }
        return ["value": v]
    }

    static let list = StepDef(
        type: "list", title: "List", description: "Sort, slice, or count a list. Wire a score into By to sort by it",
        category: .logic,
        inputs: [Port(id: "items", type: .any, label: "List", list: true), Port(id: "by", type: .any, label: "By", list: true, optional: true)],
        outputs: [Port(id: "result", type: .any, label: "Result")],
        defaults: ["op": "firstN", "n": 0], noMap: true
    ) { run in
        let op = ListOp(rawValue: run.params["op"]?.string ?? "") ?? .count
        let result = op.run(run.inputs["items"]?.items ?? [], n: op.count(run.params["n"]?.int ?? 0), by: run.inputs["by"]?.items)
        return result.map { ["result": $0] } ?? [:]
    }

    static let best = StepDef(
        type: "best", title: "Pick best", description: "The item with the highest score",
        category: .logic,
        inputs: [Port(id: "items", type: .any, label: "Items", list: true), Port(id: "scores", type: .any, label: "Scores", list: true)],
        outputs: [Port(id: "best", type: .any, label: "Best"), Port(id: "score", type: .any, label: "Score")],
        noMap: true
    ) { run in
        let items = run.inputs["items"]?.items ?? []
        let scores = (run.inputs["scores"]?.items ?? []).map { $0?.asNumber ?? .nan }
        var at = -1
        for (i, v) in scores.enumerated() where i < items.count && items[i] != nil && v.isFinite {
            if at < 0 || v > scores[at] { at = i }
        }
        guard at >= 0, let item = items[at] else { return [:] }
        return ["best": item, "score": .number(scores[at])]
    }

    static let template = StepDef(
        type: "template", title: "Template", description: "Combine values into text with {{a}}, {{b}}, {{c}}, {{date}}, and {{time}}",
        category: .logic,
        inputs: ["a", "b", "c"].map { Port(id: $0, type: .any, label: $0, optional: true) },
        outputs: [Port(id: "text", type: .text, label: "Text")],
        defaults: ["template": "{{a}}"], noMap: true
    ) { run in
        let template = run.params["template"]?.string ?? ""
        let lists = ["a", "b", "c"].filter { run.inputs[$0]?.isStream == true }
        func fill(_ i: Int?) -> String? {
            if let i, lists.contains(where: { k in let l = run.inputs[k]!.items; return i >= l.count || l[i] == nil }) { return nil }
            return Placeholders.fill(template) { key in
                guard ["a", "b", "c"].contains(key) else { return nil }
                var v = run.inputs[key]
                if let i, v?.isStream == true { v = v!.items[i] }
                return v.asText
            }
        }
        if lists.isEmpty { return ["text": .text(fill(nil) ?? "")] }
        let n = lists.map { run.inputs[$0]!.items.count }.max() ?? 0
        return Value.sparse((0..<n).map { fill($0).map(Value.text) }).map { ["text": $0] } ?? [:]
    }

    static let join = StepDef(
        type: "join", title: "Join", description: "Turn a list back into one text",
        category: .logic,
        inputs: [Port(id: "items", type: .any, label: "Items", list: true)],
        outputs: [Port(id: "text", type: .text, label: "Text")],
        defaults: ["separator": "newline"], noMap: true
    ) { run in
        let sep = ["newline": "\n", "space": " ", "comma": ", ", "paragraph": "\n\n"][run.params["separator"]?.string ?? "newline"] ?? "\n"
        return ["text": .text((run.inputs["items"]?.present ?? []).map(\.asText).joined(separator: sep))]
    }

    static let note = StepDef(
        type: "note", title: "Note", description: "A note on the canvas, for whoever opens the flow",
        category: .note, defaults: ["text": ""], noMap: true
    ) { _ in [:] }
}

private let english = Locale(identifier: "en")

/// "fr" as "French".
func languageName(_ code: String) -> String {
    guard !code.isEmpty else { return "Unknown" }
    return english.localizedString(forIdentifier: code) ?? code
}

/// The {{...}} placeholders that Template, Save to folder, Rename, and Copy
/// or move fill in, with one way to write a date and a time for all of them:
/// 2026-10-14 and 14.05.30, as macOS names screenshots, so text made from a
/// pattern also makes a good file name.
enum Placeholders {
    private static let day = format("yyyy-MM-dd")
    private static let clock = format("HH.mm.ss")

    /// Today's date or the time now.
    static func now(_ part: String) -> String { stamp(part, Date()) }

    static func stamp(_ part: String, _ date: Date) -> String {
        (part == "time" ? clock : day).string(from: date)
    }

    /// The pattern with `{{date}}` and `{{time}}` filled in from `moment`,
    /// which is only asked for when the pattern uses them, and every other
    /// placeholder from `value`. `{{a|lang}}` names the language of a code.
    /// A placeholder `value` does not know stays as it was.
    static func fill(_ pattern: String, at moment: () -> Date = { Date() }, _ value: (String) -> String?) -> String {
        var date: Date?
        return pattern.replacing(#/\{\{\s*(\w+)(\|lang)?\s*\}\}/#) { m in
            let key = String(m.output.1)
            if key == "date" || key == "time" {
                if date == nil { date = moment() }
                return stamp(key, date!)
            }
            guard let text = value(key) else { return String(m.output.0) }
            return m.output.2 != nil ? languageName(text) : text
        }
    }

    private static func format(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = pattern
        return f
    }
}
