import Foundation

struct PluralOperands {
    let n: Double, i: Double, v: Double, w: Double, f: Double, t: Double
    let c = 0.0, e = 0.0

    init(_ decimal: String) {
        let parts = decimal.split(separator: ".", omittingEmptySubsequences: false)
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        let trimmed = String(fraction.reversed().drop(while: { $0 == "0" }).reversed())
        n = abs(Double(decimal) ?? 0); i = n.rounded(.towardZero)
        v = Double(fraction.count); w = Double(trimmed.count)
        f = Double(fraction) ?? 0; t = Double(trimmed) ?? 0
    }
}

/// Shared by direct plural formatting and the optional ICU module.
/// Rules come from Unicode CLDR, not language specific output substitutions.
public func messagevisorPluralCategory(_ value: Double, locale: String, ordinal: Bool = false, options: FormatOptions = [:]) throws -> String {
    guard value.isFinite else { return "other" }
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.roundingMode = .halfUp
    func digits(_ key: String, _ fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let option = options[key] else { return fallback }
        guard let number = option.numberValue, number.isFinite, number.rounded() == number,
              number >= Double(range.lowerBound), number <= Double(range.upperBound) else {
            throw MessagevisorError("Invalid plural option: \(key)")
        }
        return Int(number)
    }
    let minimum = try digits("minimumFractionDigits", 0, range: 0...100)
    let maximum = try digits("maximumFractionDigits", max(3, minimum), range: 0...100)
    guard minimum <= maximum else { throw MessagevisorError("Invalid plural fraction digit range") }
    formatter.minimumFractionDigits = minimum
    formatter.maximumFractionDigits = maximum
    if options["minimumSignificantDigits"] != nil || options["maximumSignificantDigits"] != nil {
        let min = try digits("minimumSignificantDigits", 1, range: 1...21)
        let max = try digits("maximumSignificantDigits", 21, range: 1...21)
        guard min <= max else { throw MessagevisorError("Invalid plural significant digit range") }
        formatter.usesSignificantDigits = true
        formatter.minimumSignificantDigits = min; formatter.maximumSignificantDigits = max
    }
    let decimal = formatter.string(from: NSNumber(value: abs(value))) ?? String(abs(value))
    return pluralCategory(PluralOperands(decimal), locale: locale, ordinal: ordinal)
}

func pluralCategory(_ operands: PluralOperands, locale: String, ordinal: Bool) -> String {
    let select = ordinal ? CLDRPluralRules.ordinal : CLDRPluralRules.cardinal
    let canonical = Locale.canonicalIdentifier(from: locale).replacingOccurrences(of: "_", with: "-")
    var components = String(canonical.split(separator: "@")[0]).split(separator: "-").map(String.init)
    if let extensionIndex = components.firstIndex(where: { $0.count == 1 }) { components.removeSubrange(extensionIndex...) }
    // CLDR distinguishes regional rules such as Portuguese in Portugal.
    while !components.isEmpty {
        let candidate = components.joined(separator: "-")
        if let category = select(candidate, operands) { return category }
        if let parent = CLDRPluralRules.parents[candidate], parent != "und" {
            components = parent.split(separator: "-").map(String.init)
        } else if components.count >= 3, components[1].count == 4 {
            components.remove(at: 1)
        } else { components.removeLast() }
    }
    return "other"
}
