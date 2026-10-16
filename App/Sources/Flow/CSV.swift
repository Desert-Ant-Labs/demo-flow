import Foundation

/// Records as a spreadsheet: one row each, their fields as columns in the
/// order first seen. Numbers keep every digit. With tabs, for pasting into a
/// spreadsheet, a cell's own tabs and line breaks become spaces.
enum CSV {
    static func text(_ rows: [Value], separator: Character = ",") -> String {
        var keys: [String] = []
        for case .record(let fields) in rows {
            for (key, _) in fields where !keys.contains(key) { keys.append(key) }
        }
        func escaped(_ s: String) -> String {
            if separator == "\t" { return s.replacing(#/[\t\r\n]+/#, with: " ") }
            return s.contains(where: { $0 == separator || "\"\n\r".contains($0) }) ? "\"\(s.replacing("\"", with: "\"\""))\"" : s
        }
        func cell(_ v: Value?) -> String {
            if case .number(let n) = v { return n.wholeValue.map(String.init) ?? "\(n)" }
            return v.asText
        }
        let sep = String(separator)
        let lines = rows.map { row in keys.map { escaped(cell(row[$0])) }.joined(separator: sep) }
        return ([keys.map(escaped).joined(separator: sep)] + lines).joined(separator: "\n")
    }
}
