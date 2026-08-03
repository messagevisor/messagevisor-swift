import Foundation

public struct MessagevisorEvaluationDataProvider: Sendable {
    public var context: MessagevisorContext
    public var segments: [String: Segment]
    public var resolveFlag: FlagResolver?
    public var resolveVariation: VariationResolver?
    public init(context: MessagevisorContext = [:], segments: [String: Segment] = [:], resolveFlag: FlagResolver? = nil, resolveVariation: VariationResolver? = nil) {
        self.context = context; self.segments = segments; self.resolveFlag = resolveFlag; self.resolveVariation = resolveVariation
    }
}

private func contextValue(_ context: MessagevisorContext, path: String) -> MessagevisorValue? {
    let parts = path.split(separator: ".").map(String.init)
    guard let first = parts.first else { return nil }
    var value = context[first]
    for part in parts.dropFirst() {
        guard case .object(let object)? = value else { return nil }
        value = object[part]
    }
    return value
}

private func strictEqual(_ left: MessagevisorValue, _ right: MessagevisorValue) -> Bool {
    switch (left, right) {
    case (.int(let a), .int(let b)): return a == b
    case (.double(let a), .double(let b)): return a == b
    case (.int(let a), .double(let b)): return Double(a) == b
    case (.double(let a), .int(let b)): return a == Double(b)
    case (.string(let a), .string(let b)): return a == b
    case (.bool(let a), .bool(let b)): return a == b
    case (.date(let a), .date(let b)): return a == b
    case (.array(let a), .array(let b)): return a == b
    case (.object(let a), .object(let b)): return a == b
    case (.null, .null): return true
    default: return false
    }
}

private func parseCondition(_ value: String) -> Condition? {
    guard value.first == "{" || value.first == "[" else { return nil }
    return try? JSONDecoder().decode(Condition.self, from: Data(value.utf8))
}

private func parseGroup(_ value: String) -> GroupSegment? {
    guard value.first == "{" || value.first == "[" else { return nil }
    return try? JSONDecoder().decode(GroupSegment.self, from: Data(value.utf8))
}

private func regexOptions(_ flags: String?) -> NSRegularExpression.Options? {
    guard let flags else { return [] }
    if flags.isEmpty { return [] }
    guard flags.allSatisfy({ "imsu".contains($0) }), Set(flags).count == flags.count else { return nil }
    var result: NSRegularExpression.Options = []
    if flags.contains("i") { result.insert(.caseInsensitive) }
    if flags.contains("m") { result.insert(.anchorsMatchLines) }
    if flags.contains("s") { result.insert(.dotMatchesLineSeparators) }
    return result
}

private func matchesRegex(_ value: String, pattern: String, flags: String?) -> Bool? {
    guard let options = regexOptions(flags) else { return nil }
    guard isPortableRegexSyntax(pattern) else { return nil }
    guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return expression.firstMatch(in: value, range: range) != nil
}

private func isPortableRegexSyntax(_ pattern: String) -> Bool {
    let characters = Array(pattern)
    var inCharacterClass = false
    var index = 0
    while index < characters.count {
        let character = characters[index]
        if character == "\\" {
            if index + 1 < characters.count {
                let escaped = characters[index + 1]
                if !inCharacterClass,
                   ((escaped >= "1" && escaped <= "9")
                    || ((escaped == "k" || escaped == "g")
                        && index + 2 < characters.count
                        && (characters[index + 2] == "<" || characters[index + 2] == "'"))) {
                    return false
                }
                index += 2
                continue
            }
        }
        if character == "[" && !inCharacterClass { inCharacterClass = true; index += 1; continue }
        if character == "]" && inCharacterClass { inCharacterClass = false; index += 1; continue }
        if !inCharacterClass {
            if character == "(" && index + 1 < characters.count && characters[index + 1] == "?" { return false }
            if (character == "?" || character == "*" || character == "+"),
               index + 1 < characters.count, characters[index + 1] == "+" { return false }
            if character == "{" {
                let suffix = String(characters[index...])
                if suffix.range(of: #"^\{\d+(?:,\d*)?\}\+"#, options: .regularExpression) != nil { return false }
            }
        }
        index += 1
    }
    return true
}

private func evaluatePredicate(_ condition: ConditionPredicate, provider: MessagevisorEvaluationDataProvider) -> Bool {
    if let feature = condition.feature {
        let enabled = provider.resolveFlag?(feature, provider.context) ?? false
        if condition.operator == "isEnabled" { return enabled }
        if condition.operator == "isDisabled" { return !enabled }
        return false
    }
    if let experiment = condition.experiment {
        guard condition.operator == "hasVariation", case .string(let expected)? = condition.value else { return false }
        return provider.resolveVariation?(experiment, provider.context) == expected
    }
    guard let attribute = condition.attribute else { return false }
    let value = contextValue(provider.context, path: attribute)
    let expected = condition.value

    switch condition.operator {
    case "equals":
        guard let value, let expected else { return false }; return strictEqual(value, expected)
    case "notEquals":
        guard let expected else { return value != nil }; guard let value else { return true }; return !strictEqual(value, expected)
    case "exists": return value != nil
    case "notExists": return value == nil
    case "greaterThan", "greaterThanOrEquals", "lessThan", "lessThanOrEquals":
        guard let left = value?.numberValue, let right = expected?.numberValue else { return false }
        switch condition.operator {
        case "greaterThan": return left > right
        case "greaterThanOrEquals": return left >= right
        case "lessThan": return left < right
        default: return left <= right
        }
    case "contains", "notContains", "startsWith", "endsWith":
        guard case .string(let left)? = value, case .string(let right)? = expected else { return false }
        switch condition.operator {
        case "contains": return left.contains(right)
        case "notContains": return !left.contains(right)
        case "startsWith": return left.hasPrefix(right)
        default: return left.hasSuffix(right)
        }
    case "matches", "notMatches":
        guard case .string(let left)? = value, case .string(let right)? = expected,
              let matched = matchesRegex(left, pattern: right, flags: condition.regexFlags) else { return false }
        return condition.operator == "matches" ? matched : !matched
    case "before", "after":
        guard let left = conditionDate(value), let right = conditionDate(expected) else { return false }
        return condition.operator == "before" ? left < right : left > right
    case "includes", "notIncludes":
        guard case .array(let values)? = value, let expected else { return false }
        let included = values.contains { strictEqual($0, expected) }
        return condition.operator == "includes" ? included : !included
    case "in", "notIn":
        guard let value, case .array(let values)? = expected else { return false }
        let included = values.contains { strictEqual($0, value) }
        return condition.operator == "in" ? included : !included
    default: return false
    }
}

private func conditionDate(_ value: MessagevisorValue?) -> Date? {
    switch value {
    case .date(let date): return date
    case .string(let value): return PortableDate.parseCondition(value)
    default: return nil
    }
}

public func evaluateCondition(_ condition: Condition?, provider: MessagevisorEvaluationDataProvider = .init()) -> Bool {
    guard let condition else { return true }
    switch condition {
    case .all: return true
    case .string(let value): return parseCondition(value).map { evaluateCondition($0, provider: provider) } ?? false
    case .predicate(let value): return evaluatePredicate(value, provider: provider)
    case .list(let values), .and(let values): return values.allSatisfy { evaluateCondition($0, provider: provider) }
    case .or(let values): return values.contains { evaluateCondition($0, provider: provider) }
    case .not(let values): return !values.allSatisfy { evaluateCondition($0, provider: provider) }
    }
}

public func evaluateGroupSegment(_ group: GroupSegment?, provider: MessagevisorEvaluationDataProvider = .init()) -> Bool {
    guard let group else { return true }
    switch group {
    case .all: return true
    case .key(let value):
        if let parsed = parseGroup(value) { return evaluateGroupSegment(parsed, provider: provider) }
        return evaluateSegment(value, provider: provider)
    case .list(let values), .and(let values): return values.allSatisfy { evaluateGroupSegment($0, provider: provider) }
    case .or(let values): return values.contains { evaluateGroupSegment($0, provider: provider) }
    case .not(let values): return !values.allSatisfy { evaluateGroupSegment($0, provider: provider) }
    }
}

public func evaluateSegment(_ segmentKey: String, provider: MessagevisorEvaluationDataProvider = .init()) -> Bool {
    guard let segment = provider.segments[segmentKey], segment.archived != true else { return false }
    return evaluateCondition(segment.conditions, provider: provider)
}
