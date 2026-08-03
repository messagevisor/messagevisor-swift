import XCTest
import CoreFoundation
@testable import Messagevisor

final class PortableConformanceTests: XCTestCase {
    private var fixture: [String: Any] = [:]

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sdk-v1", withExtension: "json"))
        fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testBundledFixtureMatchesSiblingMonorepoWhenAvailable() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = repository.deletingLastPathComponent()
            .appendingPathComponent("messagevisor/conformance/sdk-v1.json")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("Sibling Messagevisor monorepo is not available")
        }
        let bundled = try XCTUnwrap(Bundle.module.url(forResource: "sdk-v1", withExtension: "json"))
        let bundledFixture = try JSONSerialization.jsonObject(with: Data(contentsOf: bundled)) as! NSDictionary
        let canonicalFixture = try JSONSerialization.jsonObject(with: Data(contentsOf: source)) as! NSDictionary
        XCTAssertEqual(bundledFixture, canonicalFixture)
    }

    func testConditionCases() throws {
        for item in fixture["conditions"] as! [[String: Any]] {
            let condition = try decode(Condition.self, item["condition"]!)
            XCTAssertEqual(evaluateCondition(condition, provider: .init(context: values(item["context"]))), item["expected"] as? Bool, item["name"] as! String)
        }
    }

    func testPortableRegexCases() throws {
        let regex = fixture["portableRegex"] as! [String: Any]
        for item in regex["accepted"] as! [[String: Any]] {
            let predicate = ConditionPredicate(attribute: "value", operator: "matches", value: .string(item["pattern"] as! String), regexFlags: item["flags"] as? String)
            XCTAssertTrue(evaluateCondition(.predicate(predicate), provider: .init(context: ["value": .string(item["value"] as! String)])))
        }
        for item in regex["rejected"] as! [[String: Any]] {
            let predicate = ConditionPredicate(attribute: "value", operator: "notMatches", value: .string(item["pattern"] as! String), regexFlags: item["flags"] as? String)
            XCTAssertFalse(evaluateCondition(.predicate(predicate), provider: .init(context: ["value": .string("other")])), item["name"] as! String)
        }
    }

    func testSegmentCases() throws {
        for item in fixture["segments"] as! [[String: Any]] {
            let segments = try decode([String: Segment].self, item["segments"]!)
            let provider = MessagevisorEvaluationDataProvider(context: values(item["context"]), segments: segments)
            let actual: Bool
            if let segment = item["segment"] as? String { actual = evaluateSegment(segment, provider: provider) }
            else { actual = evaluateGroupSegment(try decode(GroupSegment.self, item["group"]!), provider: provider) }
            XCTAssertEqual(actual, item["expected"] as? Bool, item["name"] as! String)
        }
    }

    func testTranslationCases() throws {
        for item in fixture["translations"] as! [[String: Any]] {
            let diagnostics = ConcurrencyBox<[String]>([])
            let datafile = try item["datafile"].map { try decode(DatafileContent.self, $0) }
            let defaults = item["defaultTranslations"].map { valuesByLocale($0) } ?? [:]
            let sdk = createMessagevisor(.init(datafile: datafile, locale: item["locale"] as? String, context: values(item["context"]), defaultTranslations: defaults, onDiagnostic: { diagnostic in diagnostics.mutate { $0.append(diagnostic.code) } }, logLevel: .debug))
            let actual = try sdk.translate(item["message"] as! String, options: .init(defaultTranslation: item["defaultTranslation"] as? String))
            XCTAssertEqual(actual, item["expected"] as? String, item["name"] as! String)
            for code in item["expectedDiagnosticCodes"] as? [String] ?? [] { XCTAssertTrue(diagnostics.value.contains(code), item["name"] as! String) }
        }
    }

    func testDatafileContract() throws {
        let contract = fixture["datafiles"] as! [String: Any]
        let diagnostics = ConcurrencyBox<[MessagevisorDiagnostic]>([])
        let first = try fixtureDatafile()
        let sdk = createMessagevisor(.init(datafile: first, onDiagnostic: { diagnostic in diagnostics.mutate { $0.append(diagnostic) } }, logLevel: .debug))

        var incoming = first
        incoming.revision = "2"; incoming.target = "mobile"
        incoming.messages = ["second": .init()]; incoming.translations = ["second": "Second"]
        sdk.setDatafile(incoming)
        if contract["mergeByDefault"] as? Bool == true {
            XCTAssertEqual(try sdk.getDatafile().translations["welcome"], "Base")
            XCTAssertEqual(try sdk.getDatafile().translations["second"], "Second")
        }

        var other = first; other.locale = "nl"; other.revision = "nl-1"
        sdk.setDatafile(other)
        if contract["loadingAnotherLocaleDoesNotChangeActiveLocale"] as? Bool == true { XCTAssertEqual(sdk.getLocale(), "en") }

        var replacement = first; replacement.revision = "3"
        sdk.setDatafile(replacement, replace: true)
        if contract["replaceWithSecondArgument"] as? Bool == true { XCTAssertEqual(Set(try sdk.getDatafile().translations.keys), ["welcome"]) }

        sdk.setDatafile("{invalid")
        let expected = contract["invalidDatafileDiagnostic"] as! [String: Any]
        XCTAssertEqual(diagnostics.value.last?.code, expected["code"] as? String)
        XCTAssertEqual(diagnostics.value.last?.message, expected["message"] as? String)
    }

    func testModuleLifecycleContract() async throws {
        let contract = fixture["modules"] as! [String: Any]
        let diagnostics = ConcurrencyBox<[String]>([]), closed = ConcurrencyBox<[String]>([])
        @Sendable func module(_ name: String) -> MessagevisorModule { .init(name: name, close: { closed.mutate { $0.append(name) } }) }
        let sdk = createMessagevisor(.init(onDiagnostic: { diagnostic in diagnostics.mutate { $0.append(diagnostic.code) } }, logLevel: .debug))

        _ = sdk.addModule(module("duplicate")); _ = sdk.addModule(module("duplicate"))
        _ = sdk.addModule(.init(name: "broken", setup: { _ in throw MessagevisorError("setup") }, close: { closed.mutate { $0.append("broken") } }))
        let remove = sdk.addModule(module("dynamic")); try await remove()
        if contract["removalIsIdempotent"] as? Bool == true { try await remove() }
        _ = sdk.addModule(module("first")); _ = sdk.addModule(module("last"))
        try await sdk.close()

        XCTAssertTrue(diagnostics.value.contains(contract["duplicateCode"] as! String))
        XCTAssertTrue(diagnostics.value.contains(contract["setupFailureCode"] as! String))
        XCTAssertEqual(closed.value, ["broken", "dynamic", "last", "first", "duplicate"])
    }

    func testModuleResolverRollbackContract() async throws {
        let contract = fixture["modules"] as! [String: Any]
        var datafile = try fixtureDatafile()
        datafile.segments = ["enabled": .init(conditions: .predicate(.init(feature: "flag", operator: "isEnabled")))]
        datafile.messages = ["value": .init(overrides: [.init(key: "enabled", segments: .key("enabled"), translation: "Enabled")])]
        datafile.translations = ["value": "Disabled"]
        let sdk = createMessagevisor(.init(datafile: datafile, resolveFlag: { _, _ in false }, logLevel: .fatal))
        let child = sdk.spawn()
        let remove = sdk.addModule(.init(name: "enabled", setup: { api in api.setFlagResolver { _, _ in true } }))
        XCTAssertEqual(try child.translate("value"), "Enabled")
        _ = sdk.addModule(.init(name: "broken", setup: { api in api.setFlagResolver { _, _ in false }; throw MessagevisorError("setup") }))
        if contract["failedSetupRestoresPreviousResolvers"] as? Bool == true { XCTAssertEqual(try sdk.translate("value"), "Enabled") }
        try await remove()
        if contract["removalRestoresPreviousResolvers"] as? Bool == true {
            XCTAssertEqual(try sdk.translate("value"), "Disabled"); XCTAssertEqual(try child.translate("value"), "Disabled")
        }
    }

    func testEventAndDiagnosticContracts() throws {
        let events = fixture["events"] as! [String: Any]
        let observed = ConcurrencyBox<[String]>([])
        let sdk = createMessagevisor(.init(logLevel: .fatal))
        for source in events["changeSources"] as! [String] {
            let event = try XCTUnwrap(MessagevisorEventName.allCases.first { $0.rawValue == source })
            _ = sdk.on(event) { _ in observed.mutate { $0.append(source) } }
        }
        _ = sdk.on(.change) { event in
            if case .change(let source, _) = event.details { observed.mutate { $0.append("change:\(source.rawValue)") } }
        }
        let en = try fixtureDatafile(); sdk.setDatafile(en)
        var nl = en; nl.locale = "nl"; nl.revision = "2"; sdk.setDatafile(nl)
        try sdk.setLocale("nl"); sdk.setContext(["plan": .string("pro")]); sdk.setCurrency("EUR"); sdk.setTimeZone("UTC")
        if events["stateEventBeforeChange"] as? Bool == true {
            XCTAssertEqual(observed.value, ["datafile_set", "change:datafile_set", "datafile_set", "change:datafile_set", "locale_set", "change:locale_set", "context_set", "change:context_set", "currency_set", "change:currency_set", "timeZone_set", "change:timeZone_set"])
        }

        let diagnosticsContract = fixture["diagnostics"] as! [String: Any]
        let diagnostics = ConcurrencyBox<[MessagevisorDiagnostic]>([])
        let missing = createMessagevisor(.init(locale: "en", onDiagnostic: { diagnostic in diagnostics.mutate { $0.append(diagnostic) } }, logLevel: .debug))
        _ = try missing.translate("missing")
        let formatted = createMessagevisor(.init(datafile: en, onDiagnostic: { diagnostic in diagnostics.mutate { $0.append(diagnostic) } }, logLevel: .debug))
        XCTAssertThrowsError(try formatted.formatNumber(1, preset: "missing"))
        XCTAssertThrowsError(try formatted.formatNumber(1, formatOptions: ["style": .string("currency"), "currency": .string("INVALID")]))
        let codes = Set(diagnostics.value.map(\.code))
        XCTAssertTrue(codes.contains(diagnosticsContract["missingLocaleDatafileCode"] as! String))
        XCTAssertTrue(codes.contains(diagnosticsContract["missingFormatCode"] as! String))
        XCTAssertTrue(codes.contains(diagnosticsContract["invalidFormatCode"] as! String))
    }

    func testChildOwnedDatafileEventContract() async throws {
        let events = fixture["events"] as! [String: Any]
        let first = try fixtureDatafile()
        let parent = createMessagevisor(.init(datafile: first, logLevel: .fatal))
        var nl = first; nl.locale = "nl"; nl.revision = "nl-1"; parent.setDatafile(nl)
        let child = parent.spawn(context: ["tenant": .string("child")], options: .init(locale: "nl"))
        let trace = ConcurrencyBox<[[String: Any]]>([])
        @Sendable func record(_ event: MessagevisorEvent) {
            let details: MessagevisorEventDetails
            if case .change(_, let nested) = event.details { details = nested }
            else { details = event.details }
            guard case .datafileSet(let datafile, _, let activeLocale, _, _) = details else { return }
            var item: [String: Any] = [
                "type": event.type.rawValue,
                "version": event.version,
                "snapshotVersion": event.snapshot.version,
                "previousSnapshotVersion": event.previousSnapshot.version,
                "snapshotLocale": event.snapshot.locale as Any,
                "previousSnapshotLocale": event.previousSnapshot.locale as Any,
                "datafileLocale": datafile.locale,
                "activeLocale": activeLocale as Any,
                "datafileRevision": datafile.revision,
                "snapshotDatafileRevision": event.snapshot.datafileRevisionsByLocale["en"] as Any,
                "previousSnapshotDatafileRevision": event.previousSnapshot.datafileRevisionsByLocale["en"] as Any,
            ]
            if case .change(let source, _) = event.details { item["source"] = source.rawValue }
            trace.mutate { $0.append(item) }
        }
        _ = child.on(.datafileSet) { event in
            record(event)
        }
        _ = child.on(.change) { event in
            if case .change(let source, _) = event.details, source == .datafileSet { record(event) }
        }
        var second = first; second.revision = "2"; parent.setDatafile(second, replace: true)
        let expected = events["childDatafileTrace"] as! [[String: Any]]
        XCTAssertEqual(
            try JSONSerialization.data(withJSONObject: trace.value, options: [.sortedKeys]),
            try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])
        )
        XCTAssertEqual(child.getSnapshot().version, 1)
        XCTAssertEqual(child.getSnapshot().locale, "nl")
        XCTAssertEqual(child.getContext()["tenant"], .string("child"))
        try await child.close()
        var afterClose = first; afterClose.revision = "3"; parent.setDatafile(afterClose, replace: true)
        XCTAssertEqual(trace.value.count, expected.count)
        XCTAssertEqual(trace.value.first?["datafileRevision"] as? String, events["childDatafileRevisionAfterClose"] as? String)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T { try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value)) }
    private func values(_ value: Any?) -> MessagevisorContext { (value as? [String: Any] ?? [:]).mapValues(toValue) }
    private func valuesByLocale(_ value: Any) -> [String: [String: String]] { value as? [String: [String: String]] ?? [:] }
    private func fixtureDatafile() throws -> DatafileContent {
        let first = (fixture["translations"] as! [[String: Any]])[0]
        return try decode(DatafileContent.self, first["datafile"]!)
    }
    private func toValue(_ value: Any) -> MessagevisorValue {
        if value is NSNull { return .null }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return .bool(value.boolValue) }
            return floor(value.doubleValue) == value.doubleValue ? .int(value.intValue) : .double(value.doubleValue)
        }
        if let value = value as? String { return .string(value) }; if let value = value as? [Any] { return .array(value.map(toValue)) }
        return .object((value as? [String: Any] ?? [:]).mapValues(toValue))
    }
}
