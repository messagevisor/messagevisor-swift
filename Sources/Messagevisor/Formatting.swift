import Foundation

public struct MessagevisorFormatPart: Equatable, Sendable {
    public var type: String
    public var value: String
    public init(type: String, value: String) { self.type = type; self.value = value }
}

final class NativeFormatters {
    let defaultTimeZone = TimeZone.current.identifier
    private let limit = 100
    private var numbers: [String: NumberFormatter] = [:]
    private var dates: [String: DateFormatter] = [:]
    private var numberOrder: [String] = []
    private var dateOrder: [String] = []

    private func key(_ locale: String, _ options: FormatOptions) -> String {
        ([locale] + options.keys.sorted().flatMap { [$0, options[$0]!.displayValue] }).joined(separator: "|")
    }

    private func insert<T>(_ value: T, key: String, values: inout [String: T], order: inout [String]) -> T {
        if order.count >= limit, let oldest = order.first { order.removeFirst(); values.removeValue(forKey: oldest) }
        order.append(key); values[key] = value; return value
    }

    func number(locale: String, options: FormatOptions, currency: String?) -> NumberFormatter {
        var resolved = options
        if resolved["style"]?.stringValue == "currency", resolved["currency"] == nil { resolved["currency"] = .string(currency ?? "USD") }
        let cacheKey = key(locale, resolved)
        if let formatter = numbers[cacheKey] { return formatter }
        let localeIdentifier = resolved["numberingSystem"]?.stringValue.map { "\(locale)@numbers=\($0)" } ?? locale
        let formatter = NumberFormatter(); formatter.locale = Locale(identifier: localeIdentifier)
        switch resolved["style"]?.stringValue {
        case "currency":
            if resolved["currencyDisplay"]?.stringValue == "name" { formatter.numberStyle = .currencyPlural }
            else if resolved["currencySign"]?.stringValue == "accounting" { formatter.numberStyle = .currencyAccounting }
            else { formatter.numberStyle = .currency }
            formatter.currencyCode = resolved["currency"]?.stringValue ?? currency ?? "USD"
            if resolved["currencyDisplay"]?.stringValue == "code" { formatter.currencySymbol = formatter.currencyCode }
        case "percent": formatter.numberStyle = .percent
        case "scientific": formatter.numberStyle = .scientific
        default: formatter.numberStyle = .decimal
        }
        if let value = resolved["useGrouping"]?.boolValue { formatter.usesGroupingSeparator = value }
        if let value = resolved["minimumIntegerDigits"]?.numberValue { formatter.minimumIntegerDigits = Int(value) }
        if let value = resolved["minimumFractionDigits"]?.numberValue { formatter.minimumFractionDigits = Int(value) }
        if let value = resolved["maximumFractionDigits"]?.numberValue { formatter.maximumFractionDigits = Int(value) }
        if let value = resolved["minimumSignificantDigits"]?.numberValue { formatter.minimumSignificantDigits = Int(value); formatter.usesSignificantDigits = true }
        if let value = resolved["maximumSignificantDigits"]?.numberValue { formatter.maximumSignificantDigits = Int(value); formatter.usesSignificantDigits = true }
        if resolved["notation"]?.stringValue == "scientific" { formatter.numberStyle = .scientific }
        let negative = resolved["__negative"]?.boolValue == true
        switch resolved["roundingMode"]?.stringValue {
        case "ceil": formatter.roundingMode = .ceiling
        case "floor": formatter.roundingMode = .floor
        case "expand": formatter.roundingMode = negative ? .floor : .ceiling
        case "trunc": formatter.roundingMode = negative ? .ceiling : .floor
        case "halfCeil": formatter.roundingMode = negative ? .halfDown : .halfUp
        case "halfFloor": formatter.roundingMode = negative ? .halfUp : .halfDown
        case "halfEven": formatter.roundingMode = .halfEven
        case "halfTrunc": formatter.roundingMode = .halfDown
        default: formatter.roundingMode = .halfUp
        }
        switch resolved["signDisplay"]?.stringValue {
        case "always": formatter.positivePrefix = formatter.plusSign + formatter.positivePrefix
        case "exceptZero":
            if resolved["__nonZero"]?.boolValue == true { formatter.positivePrefix = formatter.plusSign + formatter.positivePrefix }
        case "never": formatter.negativePrefix = formatter.negativePrefix.replacingOccurrences(of: formatter.minusSign, with: "")
        default: break
        }
        if resolved["trailingZeroDisplay"]?.stringValue == "stripIfInteger", resolved["__integer"]?.boolValue == true {
            formatter.minimumFractionDigits = 0
        }
        return insert(formatter, key: cacheKey, values: &numbers, order: &numberOrder)
    }

    func date(locale: String, options: FormatOptions, timeZone: String?, kind: String) -> DateFormatter {
        var resolved = options; if resolved["timeZone"] == nil, let timeZone { resolved["timeZone"] = .string(timeZone) }
        let cacheKey = key(locale + "|" + kind, resolved)
        if let formatter = dates[cacheKey] { return formatter }
        let localeIdentifier = resolved["numberingSystem"]?.stringValue.map { "\(locale)@numbers=\($0)" } ?? locale
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: localeIdentifier)
        formatter.timeZone = TimeZone(identifier: resolved["timeZone"]?.stringValue ?? timeZone ?? TimeZone.current.identifier)
        if let calendar = resolved["calendar"]?.stringValue { formatter.calendar = Calendar(identifier: calendarIdentifier(calendar)) }
        configureMessagevisorDateFormatter(formatter, options: resolved, kind: kind)
        return insert(formatter, key: cacheKey, values: &dates, order: &dateOrder)
    }


    private func calendarIdentifier(_ value: String) -> Calendar.Identifier {
        switch value { case "buddhist": return .buddhist; case "japanese": return .japanese; case "islamic": return .islamic; case "iso8601": return .iso8601; default: return .gregorian }
    }
}

func mergeFormats(_ parent: FormatPresets?, _ child: FormatPresets?, replacePresets: Bool = false) -> FormatPresets {
    func merge(_ a: [String: FormatOptions]?, _ b: [String: FormatOptions]?) -> [String: FormatOptions]? {
        guard a != nil || b != nil else { return nil }; return (a ?? [:]).merging(b ?? [:]) { old, new in replacePresets ? new : old.merging(new) { _, value in value } }
    }
    return .init(number: merge(parent?.number, child?.number), date: merge(parent?.date, child?.date), time: merge(parent?.time, child?.time), relative: merge(parent?.relative, child?.relative), dateTimeRange: merge(parent?.dateTimeRange, child?.dateTimeRange))
}
