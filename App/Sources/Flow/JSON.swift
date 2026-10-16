import Foundation

/// A step's settings as plain data, so the same YAML opens here and on the web.
enum JSON: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    var string: String? {
        switch self {
        case .string(let s): s
        // Written the same on every Mac, never as "0,5", so a number reads
        // back and compares the same whatever the language.
        case .number(let n): n.wholeValue.map { String($0) } ?? String(n)
        case .bool(let b): b ? "true" : "false"
        default: nil
        }
    }

    var number: Double? {
        switch self {
        case .number(let n): n
        case .string(let s): Double(s.trimmingCharacters(in: .whitespaces))
        case .bool(let b): b ? 1 : 0
        default: nil
        }
    }

    /// The number as a whole number, for a count or a limit: nil when it is
    /// not a number at all, and held within a range an `Int` can take, so a
    /// hand-edited 1e300 or .nan never stops the app.
    var int: Int? {
        guard let n = number, n.isFinite else { return nil }
        return Int(min(max(n, -1e15), 1e15))
    }

    var bool: Bool? {
        switch self {
        case .bool(let b): b
        case .number(let n): n != 0
        case .string(let s): ["true", "yes", "1"].contains(s.lowercased())
        default: nil
        }
    }

    var array: [JSON]? {
        if case .array(let a) = self { a } else { nil }
    }

    var object: [String: JSON]? {
        if case .object(let o) = self { o } else { nil }
    }

    var strings: [String] {
        array?.compactMap(\.string) ?? []
    }

    /// From what Yams or JSONSerialization hands back.
    init(any value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let n as NSNumber:
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let b as Bool: self = .bool(b)
        case let i as Int: self = .number(Double(i))
        case let d as Double: self = .number(d)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { JSON(any: $0) })
        case let o as [String: Any]: self = .object(o.mapValues { JSON(any: $0) })
        case let o as [AnyHashable: Any]:
            self = .object(Dictionary(o.map { ("\($0.key)", JSON(any: $0.value)) }, uniquingKeysWith: { a, _ in a }))
        default: self = .string("\(value!)")
        }
    }

    /// For Yams and JSONSerialization.
    var any: Any {
        switch self {
        case .null: NSNull()
        case .bool(let b): b
        case .number(let n): n.wholeValue.map { $0 as Any } ?? n
        case .string(let s): s
        case .array(let a): a.map(\.any)
        case .object(let o): o.mapValues(\.any)
        }
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral
{
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
}

typealias Params = [String: JSON]

extension Double {
    /// The number as an `Int` when it is whole, so a limit of 3 is written as 3
    /// rather than 3.0.
    var wholeValue: Int? {
        rounded() == self && abs(self) < 1e15 ? Int(self) : nil
    }
}
