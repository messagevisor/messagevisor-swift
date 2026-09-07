import Foundation

/// Apply the same Foundation date configuration in direct and ICU formatting.
public func configureMessagevisorDateFormatter(_ formatter: DateFormatter, options: FormatOptions, kind: String) {
    func style(_ value: String?) -> DateFormatter.Style {
        switch value { case "full": return .full; case "long": return .long; case "medium": return .medium; case "short": return .short; default: return .none }
    }
    if options["dateStyle"] != nil || options["timeStyle"] != nil {
        formatter.dateStyle = style(options["dateStyle"]?.stringValue)
        formatter.timeStyle = style(options["timeStyle"]?.stringValue)
        if options["hour12"] != nil || options["hourCycle"] != nil {
            // Rebuild a locale native pattern from its fields, not its translated literals.
            var skeleton = "", quoted = false
            for character in formatter.dateFormat ?? "" {
                if character == "'" { quoted.toggle(); continue }
                if !quoted, character.isASCII, character.isLetter {
                    if "hHKkj".contains(character) { skeleton += dateHour(options) }
                    else if character != "a" && character != "b" && character != "B" { skeleton.append(character) }
                }
            }
            if ["h", "K"].contains(dateHour(options)) { skeleton += "a" }
            formatter.setLocalizedDateFormatFromTemplate(skeleton)
        }
        return
    }
    var skeleton = ""
    func field(_ key: String, _ numeric: String, _ long: String, _ short: String, _ narrow: String) {
        guard let value = options[key]?.stringValue else { return }
        skeleton += value == "2-digit" ? numeric + numeric : value == "numeric" ? numeric : value == "long" ? long : value == "short" ? short : narrow
    }
    field("weekday", "E", "EEEE", "EEE", "EEEEE"); field("era", "G", "GGGG", "GGG", "GGGGG")
    field("year", "y", "y", "y", "y"); field("month", "M", "MMMM", "MMM", "MMMMM"); field("day", "d", "d", "d", "d")
    if options["hour"] != nil { let hour = dateHour(options); skeleton += options["hour"]?.stringValue == "2-digit" ? hour + hour : hour }
    field("minute", "m", "m", "m", "m"); field("second", "s", "s", "s", "s")
    if let digits = options["fractionalSecondDigits"]?.numberValue, digits.isFinite, (1...3).contains(digits) { skeleton += String(repeating: "S", count: Int(digits)) }
    if let zone = options["timeZoneName"]?.stringValue { skeleton += zone.hasPrefix("long") ? "zzzz" : "z" }
    if let period = options["dayPeriod"]?.stringValue {
        skeleton += period == "long" ? "BBBB" : period == "narrow" ? "BBBBB" : "B"
    } else if options["hour"] != nil, ["h", "K"].contains(dateHour(options)) {
        skeleton += "a"
    }
    formatter.setLocalizedDateFormatFromTemplate(skeleton.isEmpty ? (kind == "time" ? "jmmss" : "yMd") : skeleton)
}

private func dateHour(_ options: FormatOptions) -> String {
    // ECMA-402 gives hour12 precedence over hourCycle.
    if let hour12 = options["hour12"]?.boolValue { return hour12 ? "h" : "H" }
    switch options["hourCycle"]?.stringValue {
    case "h11": return "K"
    case "h12": return "h"
    case "h23": return "H"
    case "h24": return "k"
    default: return "j"
    }
}
