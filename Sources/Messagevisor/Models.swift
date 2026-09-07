import Foundation

public typealias FormatOptions = [String: MessagevisorValue]

public struct FormatPresets: Codable, Equatable, Sendable {
    public var number: [String: FormatOptions]?
    public var date: [String: FormatOptions]?
    public var time: [String: FormatOptions]?
    public var relative: [String: FormatOptions]?
    public var dateTimeRange: [String: FormatOptions]?

    public init(
        number: [String: FormatOptions]? = nil,
        date: [String: FormatOptions]? = nil,
        time: [String: FormatOptions]? = nil,
        relative: [String: FormatOptions]? = nil,
        dateTimeRange: [String: FormatOptions]? = nil
    ) {
        self.number = number; self.date = date; self.time = time
        self.relative = relative; self.dateTimeRange = dateTimeRange
    }

    public var isEmpty: Bool {
        [number, date, time, relative, dateTimeRange].allSatisfy { $0?.isEmpty != false }
    }
}

public struct ConditionPredicate: Codable, Equatable, Sendable {
    public var attribute: String?
    public var feature: String?
    public var experiment: String?
    public var `operator`: String
    public var value: MessagevisorValue?
    public var regexFlags: String?

    private enum CodingKeys: String, CodingKey { case attribute, feature, experiment, `operator`, value, regexFlags }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        attribute = try container.decodeIfPresent(String.self, forKey: .attribute)
        feature = try container.decodeIfPresent(String.self, forKey: .feature)
        experiment = try container.decodeIfPresent(String.self, forKey: .experiment)
        self.operator = try container.decode(String.self, forKey: .operator)
        regexFlags = try container.decodeIfPresent(String.self, forKey: .regexFlags)
        // An authored null is a comparison value, not an omitted field.
        value = container.contains(.value) ? try container.decode(MessagevisorValue.self, forKey: .value) : nil
    }

    public init(attribute: String, operator: String, value: MessagevisorValue? = nil, regexFlags: String? = nil) {
        self.attribute = attribute; self.feature = nil; self.experiment = nil
        self.operator = `operator`; self.value = value; self.regexFlags = regexFlags
    }

    public init(feature: String, operator: String) {
        self.attribute = nil; self.feature = feature; self.experiment = nil
        self.operator = `operator`; self.value = nil; self.regexFlags = nil
    }

    public init(experiment: String, operator: String = "hasVariation", value: String) {
        self.attribute = nil; self.feature = nil; self.experiment = experiment
        self.operator = `operator`; self.value = .string(value); self.regexFlags = nil
    }
}

public indirect enum Condition: Codable, Equatable, Sendable {
    case all
    case string(String)
    case predicate(ConditionPredicate)
    case list([Condition])
    case and([Condition])
    case or([Condition])
    case not([Condition])

    private enum Keys: String, CodingKey { case and, or, not }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) { self = string == "*" ? .all : .string(string); return }
        if let list = try? container.decode([Condition].self) { self = .list(list); return }
        let keyed = try decoder.container(keyedBy: Keys.self)
        if let value = try keyed.decodeIfPresent([Condition].self, forKey: .and) { self = .and(value) }
        else if let value = try keyed.decodeIfPresent([Condition].self, forKey: .or) { self = .or(value) }
        else if let value = try keyed.decodeIfPresent([Condition].self, forKey: .not) { self = .not(value) }
        else { self = .predicate(try container.decode(ConditionPredicate.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .all: var c = encoder.singleValueContainer(); try c.encode("*")
        case .string(let value): var c = encoder.singleValueContainer(); try c.encode(value)
        case .predicate(let value): var c = encoder.singleValueContainer(); try c.encode(value)
        case .list(let value): var c = encoder.singleValueContainer(); try c.encode(value)
        case .and(let value): var c = encoder.container(keyedBy: Keys.self); try c.encode(value, forKey: .and)
        case .or(let value): var c = encoder.container(keyedBy: Keys.self); try c.encode(value, forKey: .or)
        case .not(let value): var c = encoder.container(keyedBy: Keys.self); try c.encode(value, forKey: .not)
        }
    }
}

public indirect enum GroupSegment: Codable, Equatable, Sendable {
    case all
    case key(String)
    case list([GroupSegment])
    case and([GroupSegment])
    case or([GroupSegment])
    case not([GroupSegment])

    private enum Keys: String, CodingKey { case and, or, not }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) { self = string == "*" ? .all : .key(string); return }
        if let list = try? container.decode([GroupSegment].self) { self = .list(list); return }
        let keyed = try decoder.container(keyedBy: Keys.self)
        if let value = try keyed.decodeIfPresent([GroupSegment].self, forKey: .and) { self = .and(value) }
        else if let value = try keyed.decodeIfPresent([GroupSegment].self, forKey: .or) { self = .or(value) }
        else if let value = try keyed.decodeIfPresent([GroupSegment].self, forKey: .not) { self = .not(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid segment group") }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .all: var c = encoder.singleValueContainer(); try c.encode("*")
        case .key(let value): var c = encoder.singleValueContainer(); try c.encode(value)
        case .list(let value): var c = encoder.singleValueContainer(); try c.encode(value)
        case .and(let value): var c = encoder.container(keyedBy: Keys.self); try c.encode(value, forKey: .and)
        case .or(let value): var c = encoder.container(keyedBy: Keys.self); try c.encode(value, forKey: .or)
        case .not(let value): var c = encoder.container(keyedBy: Keys.self); try c.encode(value, forKey: .not)
        }
    }
}

public struct Segment: Codable, Equatable, Sendable {
    public var key: String?
    public var archived: Bool?
    public var conditions: Condition
    public init(key: String? = nil, archived: Bool? = nil, conditions: Condition) {
        self.key = key; self.archived = archived; self.conditions = conditions
    }
}

public struct MessageOverride: Codable, Equatable, Sendable {
    public var key: String
    public var conditions: Condition?
    public var segments: GroupSegment?
    public var translation: String
    public init(key: String, conditions: Condition? = nil, segments: GroupSegment? = nil, translation: String) {
        self.key = key; self.conditions = conditions; self.segments = segments; self.translation = translation
    }
}

public struct DatafileMessage: Codable, Equatable, Sendable {
    public var deprecated: Bool?
    public var deprecationWarning: String?
    public var meta: [String: MessagevisorValue]?
    public var overrides: [MessageOverride]?
    public init(deprecated: Bool? = nil, deprecationWarning: String? = nil, meta: [String: MessagevisorValue]? = nil, overrides: [MessageOverride]? = nil) {
        self.deprecated = deprecated; self.deprecationWarning = deprecationWarning; self.meta = meta; self.overrides = overrides
    }
}

public struct DatafileContent: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var messagevisorVersion: String
    public var revision: String
    public var target: String
    public var locale: String
    public var direction: String?
    public var formats: FormatPresets?
    public var segments: [String: Segment]
    public var messages: [String: DatafileMessage]
    public var translations: [String: String]

    public init(schemaVersion: String = "1", messagevisorVersion: String = "", revision: String = "1", target: String = "", locale: String, direction: String? = nil, formats: FormatPresets? = nil, segments: [String: Segment] = [:], messages: [String: DatafileMessage] = [:], translations: [String: String] = [:]) {
        self.schemaVersion = schemaVersion; self.messagevisorVersion = messagevisorVersion
        self.revision = revision; self.target = target; self.locale = locale; self.direction = direction
        self.formats = formats; self.segments = segments; self.messages = messages; self.translations = translations
    }

    public static func fromJSON(_ json: String) throws -> Self { try fromData(Data(json.utf8)) }
    public static func fromData(_ data: Data) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any],
              object["schemaVersion"] as? String == "1",
              let locale = object["locale"] as? String, !locale.isEmpty,
              ["messagevisorVersion", "revision", "target"].allSatisfy({ object[$0] is String }),
              ["segments", "messages", "translations"].allSatisfy({ object[$0] is [String: Any] }),
              object["formats"] == nil || object["formats"] is [String: Any],
              object["direction"] == nil || ["ltr", "rtl"].contains(object["direction"] as? String ?? "")
        else { throw MessagevisorError("could not parse datafile") }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    public func toJSON(pretty: Bool = false) throws -> String {
        let encoder = JSONEncoder(); if pretty { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

public typealias FlagResolver = @Sendable (_ featureKey: String, _ context: MessagevisorContext) -> Bool
public typealias VariationResolver = @Sendable (_ experimentKey: String, _ context: MessagevisorContext) -> String?

public struct EvaluationOptions: Sendable {
    public var locale: String?
    public var currency: String?
    public var timeZone: String?
    public var formats: FormatPresets?
    public var moduleOptions: [String: MessagevisorValue]?
    public init(locale: String? = nil, currency: String? = nil, timeZone: String? = nil, formats: FormatPresets? = nil, moduleOptions: [String: MessagevisorValue]? = nil) {
        self.locale = locale; self.currency = currency; self.timeZone = timeZone; self.formats = formats; self.moduleOptions = moduleOptions
    }
}

public struct TranslateOptions: Sendable {
    public var locale: String?
    public var currency: String?
    public var timeZone: String?
    public var formats: FormatPresets?
    public var moduleOptions: [String: MessagevisorValue]?
    public var context: MessagevisorContext?
    public var defaultTranslation: String?
    public init(locale: String? = nil, currency: String? = nil, timeZone: String? = nil, formats: FormatPresets? = nil, moduleOptions: [String: MessagevisorValue]? = nil, context: MessagevisorContext? = nil, defaultTranslation: String? = nil) {
        self.locale = locale; self.currency = currency; self.timeZone = timeZone; self.formats = formats
        self.moduleOptions = moduleOptions; self.context = context; self.defaultTranslation = defaultTranslation
    }
    var evaluation: EvaluationOptions { .init(locale: locale, currency: currency, timeZone: timeZone, formats: formats, moduleOptions: moduleOptions) }
}

public struct SpawnOptions: Sendable {
    public var locale: String?
    public var currency: String?
    public var timeZone: String?
    public init(locale: String? = nil, currency: String? = nil, timeZone: String? = nil) {
        self.locale = locale; self.currency = currency; self.timeZone = timeZone
    }
}

public struct MessagevisorOptions: Sendable {
    public var datafile: DatafileContent?
    public var datafileJSON: String?
    public var defaultTranslations: [String: [String: String]]
    public var defaultFormats: [String: FormatPresets]
    public var currency: String?
    public var timeZone: String?
    public var context: MessagevisorContext
    public var locale: String?
    public var resolveFlag: FlagResolver?
    public var resolveVariation: VariationResolver?
    public var onDiagnostic: MessagevisorDiagnosticHandler?
    public var logLevel: MessagevisorLogLevel
    public var modules: [MessagevisorModule]
    public init(datafile: DatafileContent? = nil, datafileJSON: String? = nil, locale: String? = nil, context: MessagevisorContext = [:], currency: String? = nil, timeZone: String? = nil, defaultTranslations: [String: [String: String]] = [:], defaultFormats: [String: FormatPresets] = [:], resolveFlag: FlagResolver? = nil, resolveVariation: VariationResolver? = nil, onDiagnostic: MessagevisorDiagnosticHandler? = nil, logLevel: MessagevisorLogLevel = .info, modules: [MessagevisorModule] = []) {
        self.datafile = datafile; self.datafileJSON = datafileJSON; self.defaultTranslations = defaultTranslations
        self.defaultFormats = defaultFormats; self.currency = currency; self.timeZone = timeZone; self.context = context
        self.locale = locale; self.resolveFlag = resolveFlag; self.resolveVariation = resolveVariation
        self.onDiagnostic = onDiagnostic; self.logLevel = logLevel; self.modules = modules
    }
}
