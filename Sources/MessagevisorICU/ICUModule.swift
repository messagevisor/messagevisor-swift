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

    mutating func render(stopAtBrace: Bool = false, evaluate: Bool = true) throws -> String {
        var output = ""
        while index < characters.count {
            let character = characters[index]
            if character == "}" && stopAtBrace { index += 1; return output }
            if character == "{" { output += try argument(evaluate: evaluate); continue }
            if character == "#", let pluralValue { if evaluate { output += try formatNumber(pluralValue, options: [:]) }; index += 1; continue }
            if character == "'" {
                if index + 1 < characters.count, characters[index + 1] == "'" { output.append("'"); index += 2; continue }
                guard index + 1 < characters.count,
                      characters[index + 1] == "{" || characters[index + 1] == "}" || (characters[index + 1] == "#" && pluralValue != nil)
                else { output.append("'"); index += 1; continue }
                index += 1
                while index < characters.count {
                    if characters[index] == "'" {
                        if index + 1 < characters.count, characters[index + 1] == "'" { output.append("'"); index += 2; continue }
                        index += 1; break
                    }
                    output.append(characters[index]); index += 1
                }
                continue
            }
            output.append(character); index += 1
        }
        if stopAtBrace { throw MessagevisorError("Unclosed ICU argument") }
        return output
    }

    mutating func argument(evaluate: Bool = true) throws -> String {
        index += 1; skipSpaces()
        let name = read(until: [",", "}"]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw MessagevisorError("ICU argument name is empty") }
        guard index < characters.count else { throw MessagevisorError("Unclosed ICU argument") }
        if characters[index] == "}" {
            index += 1
            guard evaluate else { return "" }
            guard let value = payload.values[name] else { throw MessagevisorError("Missing ICU value: \(name)") }
            return value.displayValue
        }
        index += 1; skipSpaces()
        let type = read(until: [",", "}"]).trimmingCharacters(in: .whitespaces)
        if index < characters.count, characters[index] == "}" {
            index += 1; return evaluate ? try simple(name: name, type: type, style: nil) : ""
        }
        guard index < characters.count else { throw MessagevisorError("Unclosed ICU argument") }
        index += 1
        if type == "plural" || type == "selectordinal" || type == "select" {
            return try choice(name: name, type: type, evaluate: evaluate)
        }
        let style = read(until: ["}"]).trimmingCharacters(in: .whitespaces); guard index < characters.count else { throw MessagevisorError("Unclosed ICU argument") }
        index += 1; return evaluate ? try simple(name: name, type: type, style: style) : ""
    }

    mutating func choice(name: String, type: String, evaluate: Bool = true) throws -> String {
        var choices: [String: [Character]] = [:], offset = 0.0, closed = false
        while index < characters.count {
            skipSpaces()
            guard index < characters.count else { throw MessagevisorError("Unclosed ICU choice") }
            if characters[index] == "}" { index += 1; closed = true; break }
            let selector = read(until: ["{", " ", "}"]).trimmingCharacters(in: .whitespaces)
            if selector.hasPrefix("offset:"), let value = Double(selector.dropFirst(7)) { offset = value; continue }
            skipSpaces(); guard index < characters.count, characters[index] == "{" else { throw MessagevisorError("Invalid ICU choice") }
            index += 1
            let start = index
            let selectedNumber = type == "select" ? pluralValue : payload.values[name]?.numberValue.map { $0 - offset } ?? 0
            var nested = ICUParser(characters: characters, payload: payload, api: api, index: index, pluralValue: selectedNumber)
            _ = try nested.render(stopAtBrace: true, evaluate: false); index = nested.index
            choices[selector] = Array(characters[start..<(index - 1)])
        }
        guard closed, choices["other"] != nil else { throw MessagevisorError("Invalid ICU choice") }
        guard evaluate else { return "" }
        guard let value = payload.values[name] else { throw MessagevisorError("Missing ICU value: \(name)") }
        let selected: [Character]
        let selectedNumber: Double?
        if type == "select" {
            let selector = value.stringValue ?? value.displayValue
            selected = choices[selector] ?? choices["other"]!
            selectedNumber = pluralValue
        } else {
            guard let number = value.numberValue else { throw MessagevisorError("ICU plural value \(name) is not numeric") }
            let exact = choices.first { $0.key.hasPrefix("=") && Double($0.key.dropFirst()) == number }?.value
            let category = try messagevisorPluralCategory(number - offset, locale: payload.locale, ordinal: type == "selectordinal")
            selected = exact ?? choices[category] ?? choices["other"]!
            selectedNumber = number - offset
        }
        var nested = ICUParser(characters: selected, payload: payload, api: api, index: 0, pluralValue: selectedNumber)
        return try nested.render()
    }

    func simple(name: String, type: String, style: String?) throws -> String {
        guard let value = payload.values[name] else { throw MessagevisorError("Missing ICU value: \(name)") }
        switch type {
        case "number": guard let number = value.numberValue else { throw MessagevisorError("ICU number value is not numeric") }; return try formatNumber(number, options: numberOptions(style))
        case "date", "time":
            guard let date = value.dateValue else { throw MessagevisorError("ICU date value is invalid") }
            var options = (type == "date" ? payload.formats.date?[style ?? ""] : payload.formats.time?[style ?? ""])
            if options == nil, let style, ["short", "medium", "long", "full"].contains(style) {
                options = [type == "date" ? "dateStyle" : "timeStyle": .string(style)]
            }
            return try formatDate(date, options: options ?? [:], kind: type, skeleton: style?.hasPrefix("::") == true ? String(style!.dropFirst(2)) : nil)
        default: return value.displayValue
        }
    }

    func numberOptions(_ style: String?) throws -> FormatOptions {
        guard let style, !style.isEmpty else { return [:] }
        if style.hasPrefix("::") {
            var result: FormatOptions = [:]
            for token in style.dropFirst(2).split(whereSeparator: { $0.isWhitespace }).map(String.init) {
                switch token {
                case "percent": result["style"] = .string("percent")
                case "precision-integer": result["maximumFractionDigits"] = .int(0)
                case "group-off": result["useGrouping"] = .bool(false)
                case "group-auto": result["useGrouping"] = .bool(true)
                case "sign-always": result["signDisplay"] = .string("always")
                case "sign-never": result["signDisplay"] = .string("never")
                case "sign-except-zero": result["signDisplay"] = .string("exceptZero")
                case "scientific": result["notation"] = .string("scientific")
                case "unit-width-iso-code": result["currencyDisplay"] = .string("code")
                case "unit-width-full-name": result["currencyDisplay"] = .string("name")
                case "unit-width-short": result["currencyDisplay"] = .string("symbol")
                default:
                    if token.hasPrefix("currency/"), token.dropFirst(9).range(of: "^[A-Za-z]{3}$", options: .regularExpression) != nil {
                        result["style"] = .string("currency"); result["currency"] = .string(String(token.dropFirst(9)))
                    } else if token.hasPrefix("scale/"), let scale = Double(token.dropFirst(6)), scale.isFinite {
                        result["__scale"] = .double(scale)
                    } else if token.range(of: "^\\.[0]+[#]*$", options: .regularExpression) != nil {
                        result["minimumFractionDigits"] = .int(token.filter { $0 == "0" }.count)
                        result["maximumFractionDigits"] = .int(token.count - 1)
                    } else {
                        api.reportDiagnostic(.init(level: .warn, code: "unsupported_formatter", message: "Unsupported ICU number skeleton token", details: ["formatter": .string("icu_number_skeleton"), "token": .string(token), "locale": .string(payload.locale)]))
                        throw MessagevisorError("Unsupported ICU number skeleton token: \(token)")
                    }
                }
            }
            return result
        }
        if let preset = payload.formats.number?[style] { return preset }
        switch style {
        case "percent": return ["style": .string("percent")]
        case "integer": return ["maximumFractionDigits": .int(0)]
        default: return [:]
        }
    }

    func formatNumber(_ input: Double, options: FormatOptions) throws -> String {
        let value = input * (options["__scale"]?.numberValue ?? 1)
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

    func formatDate(_ value: Date, options: FormatOptions, kind: String, skeleton: String? = nil) throws -> String {
        guard value.timeIntervalSince1970.isFinite else { try invalidFormat(type: kind, options: options, reason: "Date must be finite") }
        let numberingSystem = options["numberingSystem"]?.stringValue
        let localeIdentifier = numberingSystem.map { "\(payload.locale)@numbers=\($0)" } ?? payload.locale
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: localeIdentifier)
        let timeZone = options["timeZone"]?.stringValue ?? payload.timeZone ?? TimeZone.current.identifier
        guard let resolvedTimeZone = TimeZone(identifier: timeZone) else { try invalidFormat(type: kind, options: options, reason: "Unknown time zone: \(timeZone)") }
        formatter.timeZone = resolvedTimeZone
        formatter.calendar = calendar(options["calendar"]?.stringValue)
        if let skeleton {
            formatter.setLocalizedDateFormatFromTemplate(skeleton)
        } else {
            configureMessagevisorDateFormatter(formatter, options: options, kind: kind)
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
