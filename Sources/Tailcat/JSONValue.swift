import Foundation

/// A JSON value retaining upstream structure and unknown fields.
/// Numbers use Int64 or Double; arbitrary precision, duplicate keys and original bytes are not preserved.
extension Tailcat {
public enum JSONValue: Codable, Equatable, Sendable {
    case array([Tailcat.JSONValue])
    case bool(Bool)
    case integer(Int64)
    case null
    case number(Double)
    case object([String: Tailcat.JSONValue])
    case string(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([Tailcat.JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: Tailcat.JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .array(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .number(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }

    public subscript(_ key: String) -> Tailcat.JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    public var integerValue: Int64? {
        guard case .integer(let value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}
}

extension Tailcat {
public typealias Metadata = [String: Tailcat.JSONValue]
}

extension Encodable {
    func jsonValue() throws -> Tailcat.JSONValue {
        try JSONDecoder().decode(Tailcat.JSONValue.self, from: JSONEncoder().encode(self))
    }
}

extension Tailcat.JSONValue {
    func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}

func nanoseconds(_ duration: Duration) throws -> Int64 {
    let components = duration.components
    let (seconds, overflow) = components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
    let (result, additionOverflow) = seconds.addingReportingOverflow(components.attoseconds / 1_000_000_000)
    guard !overflow, !additionOverflow else { throw Tailcat.Failure.invalidInput("duration is too large") }
    return result
}

func unixNanoseconds(_ date: Date) throws -> Int64 {
    let value = date.timeIntervalSince1970 * 1_000_000_000
    guard value.isFinite, value > Double(Int64.min), value < Double(Int64.max) else {
        throw Tailcat.Failure.invalidInput("date is outside the supported range")
    }
    return Int64(value)
}
