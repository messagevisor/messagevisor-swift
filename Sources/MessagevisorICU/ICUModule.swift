import Foundation
import Messagevisor

public struct ICUModuleOptions: Sendable {
    public var name: String
    public var ignoreTags: Bool
    public init(name: String = "icu", ignoreTags: Bool = true) { self.name = name; self.ignoreTags = ignoreTags }
}

public func createICUModule(_ options: ICUModuleOptions = .init()) -> MessagevisorModule {
    MessagevisorModule(name: options.name, format: { payload, api in
        let runtimeIgnoreTags = payload.moduleOptions?[options.name]?.objectValue?["ignoreTags"]?.boolValue
        if runtimeIgnoreTags == false || (runtimeIgnoreTags == nil && !options.ignoreTags) {
            api.reportDiagnostic(.init(
                level: .warn,
                code: "unsupported_formatter",
                message: "Rich ICU tag callbacks are not supported by the Swift string API",
                details: ["formatter": .string("icu_rich_text"), "locale": .string(payload.locale)]
            ))
        }
        var parser = ICUParser(payload: payload, api: api)
        return try parser.render()
    })
}

private struct ICUParser {
    let characters: [Character]
    let payload: MessagevisorFormatPayload
    let api: MessagevisorModuleApi
    var index = 0
    var pluralValue: Double?

    init(payload: MessagevisorFormatPayload, api: MessagevisorModuleApi) { self.characters = Array(payload.translation); self.payload = payload; self.api = api }
    private init(characters: [Character], payload: MessagevisorFormatPayload, api: MessagevisorModuleApi, index: Int, pluralValue: Double?) {
        self.characters = characters; self.payload = payload; self.api = api; self.index = index; self.pluralValue = pluralValue
    }

    mutating func render(stopAtBrace: Bool = false) throws -> String {
        var output = ""
        while index < characters.count {
            let character = characters[index]
            if character == "}" && stopAtBrace { index += 1; return output }
            if character == "{" { output += try argument(); continue }
            if character == "#", let pluralValue { output += try formatNumber(pluralValue, options: [:]); index += 1; continue }
            if character == "'" {
                if index + 1 < characters.count, characters[index + 1] == "'" { output.append("'"); index += 2; continue }
                index += 1
                while index < characters.count, characters[index] != "'" { output.append(characters[index]); index += 1 }
                if index < characters.count { index += 1 }
                continue
            }
            output.append(character); index += 1
        }
        if stopAtBrace { throw MessagevisorError("Unclosed ICU argument") }
        return output
    }

    mutating func argument() throws -> String {
        index += 1; skipSpaces()
        let name = read(until: [",", "}"]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw MessagevisorError("ICU argument name is empty") }
        guard index < characters.count else { throw MessagevisorError("Unclosed ICU argument") }
        if characters[index] == "}" { index += 1; return payload.values[name]?.displayValue ?? "{\(name)}" }
        index += 1; skipSpaces()
        let type = read(until: [",", "}"]).trimmingCharacters(in: .whitespaces)
        if index < characters.count, characters[index] == "}" {
            index += 1; return try simple(value: payload.values[name], type: type, style: nil)
        }
        guard index < characters.count else { throw MessagevisorError("Unclosed ICU argument") }
        index += 1
        if type == "plural" || type == "selectordinal" || type == "select" {
            return try choice(name: name, type: type)
        }
        let style = read(until: ["}"]).trimmingCharacters(in: .whitespaces); guard index < characters.count else { throw MessagevisorError("Unclosed ICU argument") }
        index += 1; return try simple(value: payload.values[name], type: type, style: style)
    }

    mutating func choice(name: String, type: String) throws -> String {
        var choices: [String: String] = [:], offset = 0.0
        while index < characters.count {
            skipSpaces()
            if characters[index] == "}" { index += 1; break }
            let selector = read(until: ["{", " ", "}"]).trimmingCharacters(in: .whitespaces)
            if selector.hasPrefix("offset:"), let value = Double(selector.dropFirst(7)) { offset = value; continue }
            skipSpaces(); guard index < characters.count, characters[index] == "{" else { throw MessagevisorError("Invalid ICU choice") }
            index += 1
            let selectedNumber = payload.values[name]?.numberValue.map { $0 - offset }
            var nested = ICUParser(characters: characters, payload: payload, api: api, index: index, pluralValue: selectedNumber)
            choices[selector] = try nested.render(stopAtBrace: true); index = nested.index
        }
        if type == "select" {
            let selector = payload.values[name]?.stringValue ?? payload.values[name]?.displayValue ?? "other"
            return choices[selector] ?? choices["other"] ?? ""
        }
        guard let number = payload.values[name]?.numberValue else { throw MessagevisorError("ICU plural value \(name) is not numeric") }
        let exact = number.rounded() == number ? "=\(Int(number))" : "=\(number)"
        let category = pluralCategory(number - offset, locale: payload.locale, ordinal: type == "selectordinal")
        return choices[exact] ?? choices[category] ?? choices["other"] ?? ""
    }

    func simple(value: MessagevisorValue?, type: String, style: String?) throws -> String {
        guard let value else { return "" }
        switch type {
        case "number": guard let number = value.numberValue else { throw MessagevisorError("ICU number value is not numeric") }; return try formatNumber(number, options: payload.formats.number?[style ?? ""] ?? [:])
        case "date", "time": guard let date = value.dateValue else { throw MessagevisorError("ICU date value is invalid") }; return try formatDate(date, options: type == "date" ? payload.formats.date?[style ?? ""] ?? [:] : payload.formats.time?[style ?? ""] ?? [:], kind: type)
        default: return value.displayValue
        }
    }

    func formatNumber(_ value: Double, options: FormatOptions) throws -> String {
        if options["roundingPriority"] != nil || options["useGrouping"]?.stringValue == "min2" {
            api.reportDiagnostic(.init(level: .warn, code: "unsupported_formatter", message: "Apple NumberFormatter does not expose every ECMA-402 number option", details: ["formatter": .string("number"), "locale": .string(payload.locale)]))
        }
        let numberingSystem = options["numberingSystem"]?.stringValue
        let localeIdentifier = numberingSystem.map { "\(payload.locale)@numbers=\($0)" } ?? payload.locale
        let formatter = NumberFormatter(); formatter.locale = Locale(identifier: localeIdentifier); formatter.roundingMode = .halfUp
        switch options["style"]?.stringValue {
        case "currency":
            let code = options["currency"]?.stringValue ?? payload.currency ?? "USD"
            guard code.range(of: "^[A-Za-z]{3}$", options: .regularExpression) != nil else { try invalidFormat(type: "number", options: options, reason: "Currency must be a three-letter code") }
            if options["currencyDisplay"]?.stringValue == "name" { formatter.numberStyle = .currencyPlural }
            else { formatter.numberStyle = options["currencySign"]?.stringValue == "accounting" ? .currencyAccounting : .currency }
            formatter.currencyCode = code
            if options["currencyDisplay"]?.stringValue == "code" { formatter.currencySymbol = formatter.currencyCode }
        case "percent": formatter.numberStyle = .percent
        case "unit": return formatUnit(value, options: options, locale: localeIdentifier)
        default: formatter.numberStyle = .decimal
        }
        if let n = options["minimumFractionDigits"]?.numberValue { formatter.minimumFractionDigits = Int(n) }
        if let n = options["maximumFractionDigits"]?.numberValue { formatter.maximumFractionDigits = Int(n) }
        if let n = options["minimumIntegerDigits"]?.numberValue { formatter.minimumIntegerDigits = Int(n) }
        if let n = options["minimumSignificantDigits"]?.numberValue { formatter.minimumSignificantDigits = Int(n); formatter.usesSignificantDigits = true }
        if let n = options["maximumSignificantDigits"]?.numberValue { formatter.maximumSignificantDigits = Int(n); formatter.usesSignificantDigits = true }
        if let grouping = options["useGrouping"]?.boolValue { formatter.usesGroupingSeparator = grouping }
        if let increment = options["roundingIncrement"]?.numberValue, let digits = options["maximumFractionDigits"]?.numberValue { formatter.roundingIncrement = NSNumber(value: increment / pow(10, digits)) }
        if let mode = options["roundingMode"]?.stringValue {
            formatter.roundingMode = ["ceil": .ceiling, "floor": .floor, "expand": value < 0 ? .floor : .ceiling, "trunc": value < 0 ? .ceiling : .floor, "halfEven": .halfEven, "halfCeil": value < 0 ? .halfDown : .halfUp, "halfFloor": value < 0 ? .halfUp : .halfDown, "halfExpand": .halfUp, "halfTrunc": .halfDown].first(where: { $0.key == mode })?.value ?? .halfUp
        }
        if options["notation"]?.stringValue == "scientific" || options["notation"]?.stringValue == "engineering" { formatter.numberStyle = .scientific; formatter.positiveFormat = "0.###E0" }
        if options["notation"]?.stringValue == "compact" { return compact(value, options: options, locale: localeIdentifier) }
        switch options["signDisplay"]?.stringValue {
        case "always": formatter.positivePrefix = formatter.plusSign + formatter.positivePrefix
        case "exceptZero": if value != 0 { formatter.positivePrefix = formatter.plusSign + formatter.positivePrefix }
        case "never": formatter.negativePrefix = formatter.negativePrefix.replacingOccurrences(of: formatter.minusSign, with: "")
        default: break
        }
        var result = formatter.string(from: NSNumber(value: value)) ?? String(value)
        if options["trailingZeroDisplay"]?.stringValue == "stripIfInteger", value.rounded() == value {
            formatter.minimumFractionDigits = 0; result = formatter.string(from: NSNumber(value: value)) ?? result
        }
        return result
    }

    func formatDate(_ value: Date, options: FormatOptions, kind: String) throws -> String {
        let numberingSystem = options["numberingSystem"]?.stringValue
        let localeIdentifier = numberingSystem.map { "\(payload.locale)@numbers=\($0)" } ?? payload.locale
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: localeIdentifier)
        let timeZone = options["timeZone"]?.stringValue ?? payload.timeZone ?? TimeZone.current.identifier
        guard let resolvedTimeZone = TimeZone(identifier: timeZone) else { try invalidFormat(type: kind, options: options, reason: "Unknown time zone: \(timeZone)") }
        formatter.timeZone = resolvedTimeZone
        formatter.calendar = calendar(options["calendar"]?.stringValue)
        if let style = options[kind == "date" ? "dateStyle" : "timeStyle"]?.stringValue {
            let mapped: DateFormatter.Style = style == "full" ? .full : style == "long" ? .long : style == "medium" ? .medium : .short
            if kind == "date" { formatter.dateStyle = mapped; formatter.timeStyle = .none } else { formatter.timeStyle = mapped; formatter.dateStyle = .none }
        } else {
            formatter.setLocalizedDateFormatFromTemplate(template(options, kind: kind))
        }
        return formatter.string(from: value)
    }

    func formatUnit(_ value: Double, options: FormatOptions, locale: String) -> String {
        let formatter = MeasurementFormatter(); formatter.locale = Locale(identifier: locale); formatter.unitOptions = .providedUnit
        switch options["unitDisplay"]?.stringValue { case "long": formatter.unitStyle = .long; case "narrow": formatter.unitStyle = .short; default: formatter.unitStyle = .medium }
        switch options["unit"]?.stringValue { case "meter": return formatter.string(from: Measurement(value: value, unit: UnitLength.meters)); default: return formatter.string(from: Measurement(value: value, unit: UnitLength.kilometers)) }
    }

    func compact(_ value: Double, options: FormatOptions, locale: String) -> String {
        if options["compactDisplay"]?.stringValue == "long" {
            api.reportDiagnostic(.init(level: .warn, code: "unsupported_formatter", message: "Apple compact number formatting uses the platform's native compact style", details: ["formatter": .string("number"), "locale": .string(payload.locale)]))
        }
        if #available(macOS 12, iOS 15, tvOS 15, watchOS 8, visionOS 1, *) {
            return value.formatted(.number.notation(.compactName).rounded(rule: .toNearestOrAwayFromZero).locale(Locale(identifier: locale)))
        }
        api.reportDiagnostic(.init(level: .warn, code: "unsupported_formatter", message: "Compact number formatting requires a newer Apple runtime", details: ["formatter": .string("number"), "locale": .string(payload.locale)]))
        let formatter = NumberFormatter(); formatter.locale = Locale(identifier: locale); formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    func calendar(_ value: String?) -> Calendar {
        switch value { case "buddhist": return Calendar(identifier: .buddhist); case "japanese": return Calendar(identifier: .japanese); case "islamic": return Calendar(identifier: .islamic); default: return Calendar(identifier: .gregorian) }
    }

    func template(_ options: FormatOptions, kind: String) -> String {
        func field(_ key: String, numeric: String, long: String) -> String {
            guard let value = options[key]?.stringValue else { return "" }
            if value == "2-digit" { return numeric + numeric }; if value == "numeric" { return numeric }
            if value == "long" { return long }; if value == "short" { return key == "month" ? "MMM" : key == "weekday" ? "EEE" : key == "era" ? "GGG" : numeric }
            return key == "month" ? "MMMMM" : key == "weekday" ? "EEEEE" : key == "era" ? "GGGGG" : numeric
        }
        if kind == "date" {
            return field("weekday", numeric: "E", long: "EEEE") + field("era", numeric: "G", long: "GGGG") + field("year", numeric: "y", long: "y") + field("month", numeric: "M", long: "MMMM") + field("day", numeric: "d", long: "d")
        }
        let hourCycle = options["hourCycle"]?.stringValue
        let hour: String
        switch hourCycle {
        case "h11": hour = "K"
        case "h12": hour = "h"
        case "h23": hour = "H"
        case "h24": hour = "k"
        default:
            if options["hour12"]?.boolValue == true { hour = "h" }
            else if options["hour12"]?.boolValue == false { hour = "H" }
            else { hour = "j" }
        }
        var result = options["hour"] == nil ? "" : (options["hour"]?.stringValue == "2-digit" ? hour + hour : hour)
        result += field("minute", numeric: "m", long: "m") + field("second", numeric: "s", long: "s")
        if let digits = options["fractionalSecondDigits"]?.numberValue { result += String(repeating: "S", count: Int(digits)) }
        if options["dayPeriod"] != nil || options["hour12"]?.boolValue == true { result += "a" }
        if let zone = options["timeZoneName"]?.stringValue { result += zone.hasPrefix("long") ? "zzzz" : "z" }
        return result.isEmpty ? "jm" : result
    }

    mutating func skipSpaces() { while index < characters.count, characters[index].isWhitespace { index += 1 } }
    mutating func read(until delimiters: Set<Character>) -> String {
        let start = index; while index < characters.count, !delimiters.contains(characters[index]) { index += 1 }
        return String(characters[start..<index])
    }

    func invalidFormat(type: String, options: FormatOptions, reason: String) throws -> Never {
        let error = MessagevisorError(reason)
        api.reportDiagnostic(.init(level: .error, code: "invalid_format", message: "Invalid format options", details: ["locale": .string(payload.locale), "type": .string(type), "options": .object(options)], originalError: error.localizedDescription))
        throw error
    }
}

private func pluralCategory(_ value: Double, locale: String, ordinal: Bool) -> String {
    if ordinal, locale.lowercased().hasPrefix("en") {
        let integer = Int(value), mod10 = integer % 10, mod100 = integer % 100
        if mod10 == 1 && mod100 != 11 { return "one" }
        if mod10 == 2 && mod100 != 12 { return "two" }
        if mod10 == 3 && mod100 != 13 { return "few" }
        return "other"
    }
    let language = locale.split(separator: "-").first.map(String.init)?.lowercased() ?? locale.lowercased()
    switch language {
    case "fr", "pt": return value == 0 || value == 1 ? "one" : "other"
    case "ru", "uk":
        let n = Int(value), mod10 = n % 10, mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return "one" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "few" }
        if mod10 == 0 || (5...9).contains(mod10) || (11...14).contains(mod100) { return "many" }
        return "other"
    case "ar":
        let n = Int(value)
        if n == 0 { return "zero" }; if n == 1 { return "one" }; if n == 2 { return "two" }
        if (3...10).contains(n % 100) { return "few" }; if (11...99).contains(n % 100) { return "many" }
        return "other"
    default: return value == 1 ? "one" : "other"
    }
}
