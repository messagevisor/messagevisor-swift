import XCTest
@testable import Messagevisor

final class ConditionsTests: XCTestCase {
    private func match(_ predicate: ConditionPredicate, _ context: MessagevisorContext) -> Bool {
        evaluateCondition(.predicate(predicate), provider: .init(context: context))
    }

    func testAttributeOperatorsAreTypeStrict() {
        XCTAssertTrue(match(.init(attribute: "n", operator: "greaterThan", value: .int(4)), ["n": .int(5)]))
        XCTAssertFalse(match(.init(attribute: "n", operator: "greaterThan", value: .int(4)), ["n": .string("5")]))
        XCTAssertTrue(match(.init(attribute: "s", operator: "contains", value: .string("vis")), ["s": .string("messagevisor")]))
        XCTAssertFalse(match(.init(attribute: "s", operator: "notContains", value: .string("x")), ["s": .int(1)]))
        XCTAssertTrue(match(.init(attribute: "s", operator: "startsWith", value: .string("mes")), ["s": .string("message")]))
        XCTAssertTrue(match(.init(attribute: "s", operator: "endsWith", value: .string("age")), ["s": .string("message")]))
        XCTAssertTrue(match(.init(attribute: "a", operator: "includes", value: .string("pro")), ["a": .array([.string("pro")])]))
        XCTAssertTrue(match(.init(attribute: "v", operator: "in", value: .array([.string("pro")])), ["v": .string("pro")]))
        XCTAssertFalse(match(.init(attribute: "v", operator: "notIn", value: .string("pro")), ["v": .string("free")]))
    }

    func testExistenceNullAndNestedContext() {
        XCTAssertTrue(match(.init(attribute: "value", operator: "exists"), ["value": .null]))
        XCTAssertTrue(match(.init(attribute: "missing", operator: "notExists"), [:]))
        XCTAssertTrue(match(.init(attribute: "user.plan", operator: "equals", value: .string("pro")), ["user": .object(["plan": .string("pro")])]))
        XCTAssertTrue(match(.init(attribute: "missing", operator: "notEquals", value: .string("x")), [:]))
    }

    func testRegexDateAndResolvers() {
        XCTAssertTrue(match(.init(attribute: "value", operator: "matches", value: .string("^checkout-[0-9]+$"), regexFlags: "i"), ["value": .string("Checkout-42")]))
        XCTAssertFalse(match(.init(attribute: "value", operator: "matches", value: .string("[")), ["value": .string("x")]))
        XCTAssertFalse(match(.init(attribute: "value", operator: "matches", value: .string("x"), regexFlags: "g"), ["value": .string("x")]))
        XCTAssertFalse(match(.init(attribute: "value", operator: "matches", value: .string("x"), regexFlags: "ii"), ["value": .string("x")]))
        XCTAssertTrue(match(.init(attribute: "value", operator: "matches", value: .string("x"), regexFlags: ""), ["value": .string("x")]))
        XCTAssertTrue(match(.init(attribute: "when", operator: "before", value: .string("2026-02-01T00:00:00Z")), ["when": .string("2026-01-01T00:00:00Z")]))
        XCTAssertFalse(match(.init(attribute: "when", operator: "before", value: .string("2026-02-01")), ["when": .string("2026-01-01")]))
        XCTAssertFalse(match(.init(attribute: "when", operator: "before", value: .string("2026-02-01T00:00:00.123456Z")), ["when": .string("2026-01-01T00:00:00.123456Z")]))
        XCTAssertFalse(match(.init(attribute: "when", operator: "before", value: .int(2)), ["when": .int(1)]))
        let provider = MessagevisorEvaluationDataProvider(context: [:], resolveFlag: { key, _ in key == "enabled" }, resolveVariation: { _, _ in "control" })
        XCTAssertTrue(evaluateCondition(.predicate(.init(feature: "enabled", operator: "isEnabled")), provider: provider))
        XCTAssertTrue(evaluateCondition(.predicate(.init(experiment: "checkout", value: "control")), provider: provider))
    }

    func testRejectsNonportableRegexSyntax() {
        for pattern in ["value(?=x)", "(?<=x)value", "(?:value)", "(?<name>value)", "(value)\\1", "(?<name>value)\\k<name>", "value++"] {
            XCTAssertFalse(match(.init(attribute: "value", operator: "matches", value: .string(pattern)), ["value": .string("valuex")]), pattern)
            XCTAssertFalse(match(.init(attribute: "value", operator: "notMatches", value: .string(pattern)), ["value": .string("other")]), pattern)
        }
    }

    func testBooleanTreesStringificationAndSegments() throws {
        let yes = Condition.predicate(.init(attribute: "yes", operator: "equals", value: .bool(true)))
        let no = Condition.predicate(.init(attribute: "no", operator: "equals", value: .bool(true)))
        let provider = MessagevisorEvaluationDataProvider(context: ["yes": .bool(true), "no": .bool(false)], segments: ["yes": .init(conditions: yes), "archived": .init(archived: true, conditions: .all)])
        XCTAssertTrue(evaluateCondition(.list([yes]), provider: provider))
        XCTAssertTrue(evaluateCondition(.or([no, yes]), provider: provider))
        XCTAssertTrue(evaluateCondition(.not([yes, no]), provider: provider))
        XCTAssertFalse(evaluateCondition(.not([]), provider: provider))
        XCTAssertTrue(evaluateCondition(.string(#"{"attribute":"yes","operator":"equals","value":true}"#), provider: provider))
        XCTAssertTrue(evaluateGroupSegment(.key("yes"), provider: provider))
        XCTAssertFalse(evaluateGroupSegment(.key("missing"), provider: provider))
        XCTAssertFalse(evaluateGroupSegment(.key("archived"), provider: provider))
        XCTAssertTrue(evaluateGroupSegment(.key(#"{"not":["yes","missing"]}"#), provider: provider))
        XCTAssertFalse(evaluateGroupSegment(.not([]), provider: provider))
    }
}
