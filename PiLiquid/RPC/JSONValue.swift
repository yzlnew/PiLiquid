import Foundation

/// A minimal `Codable` representation of arbitrary JSON. Used to hold the
/// loosely-typed `data` payloads and tool arguments that pi's RPC protocol
/// returns, without forcing us to model every nested shape up front.
enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    // Convenience accessors --------------------------------------------------

    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var doubleValue: Double? { if case .number(let n) = self { return n }; return nil }
    var intValue: Int? { doubleValue.map(Int.init) }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    subscript(_ key: String) -> JSONValue? { objectValue?[key] }

    /// A compact, human-readable rendering — used to show raw tool arguments.
    var displayString: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return String(b)
        case .number(let n):
            if n == n.rounded() { return String(Int(n)) }
            return String(n)
        case .string(let s): return s
        case .array, .object:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(self), let s = String(data: data, encoding: .utf8) {
                return s
            }
            return ""
        }
    }
}
