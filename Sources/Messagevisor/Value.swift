import Foundation

/// A portable Messagevisor value used by context, message values, metadata, and format options.
public enum MessagevisorValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case date(Date)
    case array([MessagevisorValue])
    case object([String: MessagevisorValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([MessagevisorValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: MessagevisorValue].self) { self = .object(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported Messagevisor value") }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .date(let value): try container.encode(ISO8601DateFormatter().string(from: value))
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    public var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
    public var arrayValue: [MessagevisorValue]? { if case .array(let value) = self { return value }; return nil }
    public var objectValue: [String: MessagevisorValue]? { if case .object(let value) = self { return value }; return nil }
    public var numberValue: Double? {
        switch self { case .int(let value): return Double(value); case .double(let value): return value; default: return nil }
    }
    public var dateValue: Date? {
        switch self {
        case .date(let value): return value
        case .string(let value): return PortableDate.parse(value)
        case .int(let value): return Date(timeIntervalSince1970: Double(value) / 1_000)
        case .double(let value): return Date(timeIntervalSince1970: value / 1_000)
        default: return nil
        }
    }
    public var displayValue: String {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return String(value)
        case .date(let value): return ISO8601DateFormatter().string(from: value)
        case .array(let value): return value.map(\.displayValue).joined(separator: ", ")
        case .object: return "[object]"
        case .null: return ""
        }
    }
}

public typealias MessagevisorContext = [String: MessagevisorValue]
public typealias MessagevisorValues = [String: MessagevisorValue]

enum PortableDate {
    private static let formatExpression = try! NSRegularExpression(
        pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$"#
    )
    private static let conditionExpression = try! NSRegularExpression(
        pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?(?:Z|[+-]\d{2}:\d{2})$"#
    )

    static func parse(_ value: String) -> Date? {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard formatExpression.firstMatch(in: value, range: range) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: value) { return parsed }

        // ISO8601DateFormatter support for sub-millisecond precision differs by
        // Apple platform version. Date stores fractional seconds as a Double, so
        // trimming to milliseconds is a safe parsing fallback for SDK inputs.
        if let dot = value.firstIndex(of: "."), let zone = value[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let fractionStart = value.index(after: dot)
            let fraction = value[fractionStart..<zone]
            if fraction.count > 3 {
                let normalized = value[..<fractionStart] + fraction.prefix(3) + value[zone...]
                return formatter.date(from: String(normalized))
            }
        }
        return ISO8601DateFormatter().date(from: value)
    }

    static func parseCondition(_ value: String) -> Date? {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard conditionExpression.firstMatch(in: value, range: range) != nil else { return nil }
        return parse(value)
    }
}

public extension MessagevisorValue {
    static func value(_ value: String) -> Self { .string(value) }
    static func value(_ value: Int) -> Self { .int(value) }
    static func value(_ value: Double) -> Self { .double(value) }
    static func value(_ value: Bool) -> Self { .bool(value) }
}
