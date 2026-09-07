import XCTest
import CoreFoundation
@testable import Messagevisor
import MessagevisorICU

final class PortableConformanceTests: XCTestCase {
    private var fixture: [String: Any] = [:]

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sdk-v1", withExtension: "json"))
        fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testCanonicalCoverageInventory() throws {
        // Metadata describes scope. Every behavioural section below is exercised by this suite.
        XCTAssertEqual(fixture["fixtureVersion"] as? Int, 5)
        XCTAssertEqual(Set(fixture.keys), ["fixtureVersion", "description", "runtimeVariability", "icuSemantics", "pluralSemantics", "hardening", "portableRegex", "conditions", "segments", "translations", "datafiles", "modules", "diagnostics", "events"])
        let hardening = try XCTUnwrap(fixture["hardening"] as? [String: Any])
        XCTAssertEqual(Set(hardening.keys), ["dictionaryKeys", "formatMerge", "datafileValidation", "moduleSetup", "errors", "timeZones", "fallbacks"])
        // JS fallbacks for absent Intl constructors are not available branches on Foundation.
        // Swift executes missingListPartsMethod with native output and diagnoses its simplified parts.
        let fallback = try XCTUnwrap(hardening["fallbacks"] as? [String: Any])
        XCTAssertEqual(fallback["missingListPartsMethod"] as? String, "single literal containing native list output")
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

    func testCanonicalICUSemantics() throws {
        let cases = try XCTUnwrap(fixture["icuSemantics"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for item in cases {
            let id = try XCTUnwrap(item["id"] as? String)
            let diagnostics = ConcurrencyBox<[String]>([])
            let sdk = createMessagevisor(.init(locale: try XCTUnwrap(item["locale"] as? String), onDiagnostic: { diagnostic in diagnostics.mutate { $0.append(diagnostic.code) } }, logLevel: .debug, modules: [createICUModule()]))
            let message = try XCTUnwrap(item["message"] as? String)
            if let expectedError = item["error"] as? String {
                XCTAssertThrowsError(try sdk.formatMessage(message, values: values(item["values"])), id)
                XCTAssertTrue(diagnostics.value.contains(expectedError), id)
            } else {
                XCTAssertEqual(try sdk.formatMessage(message, values: values(item["values"])), try XCTUnwrap(item["expected"] as? String), id)
                XCTAssertFalse(diagnostics.value.contains("invalid_message"), id)
                XCTAssertFalse(diagnostics.value.contains("unsupported_formatter"), id)
            }
        }
    }

    func testCanonicalPluralSemantics() throws {
        let cases = try XCTUnwrap(fixture["pluralSemantics"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for item in cases {
            let locale = try XCTUnwrap(item["locale"] as? String)
            let sdk = createMessagevisor(.init(locale: locale, logLevel: .fatal))
            let value = try XCTUnwrap((item["value"] as? NSNumber)?.doubleValue)
            XCTAssertEqual(try sdk.formatPlural(value, formatOptions: values(item["options"])), item["expected"] as? String, locale)
        }
    }

    func testPortableRegexCases() throws {
        let regex = fixture["portableRegex"] as! [String: Any]
        let flagCases: [String: (String, String)] = ["i": ("^a$", "A"), "m": ("^a$", "b\na\nc"), "s": ("^a.b$", "a\nb"), "u": ("^.$", "😀")]
        for flag in regex["flags"] as! [String] {
            let (pattern, value) = try XCTUnwrap(flagCases[flag], "Add executable coverage for flag \(flag)")
            XCTAssertTrue(evaluateCondition(.predicate(.init(attribute: "value", operator: "matches", value: .string(pattern), regexFlags: flag)), provider: .init(context: ["value": .string(value)])), flag)
        }
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
        let initiallyEmpty = createMessagevisor(.init(logLevel: .fatal))
        XCTAssertNil(initiallyEmpty.getLocale())
        initiallyEmpty.setDatafile(first)
        XCTAssertEqual(initiallyEmpty.getLocale() == first.locale, contract["firstLoadedLocaleBecomesActive"] as? Bool)

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
        XCTAssertEqual(contract["storageKey"] as? String, "locale")
        XCTAssertEqual(sdk.getSnapshot().datafileLocales, [first.locale, other.locale].sorted())
        XCTAssertEqual(try sdk.getDatafile(locale: first.locale).target, "mobile")
        XCTAssertEqual(try sdk.getDatafile(locale: other.locale).revision, other.revision)
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

    func testCanonicalModuleCloseFailureAndOrder() async throws {
        let contract = try XCTUnwrap(fixture["modules"] as? [String: Any])
        let closed = ConcurrencyBox<[String]>([]), diagnostics = ConcurrencyBox<[MessagevisorDiagnostic]>([])
        let sdk = createMessagevisor(.init(logLevel: .fatal))
        let remove = sdk.addModule(.init(name: "removed", close: { closed.mutate { $0.append("removed") } }))
        try await remove()
        XCTAssertEqual(!closed.value.isEmpty, contract["removalClosesModule"] as? Bool)
        let errors = createMessagevisor(.init(onDiagnostic: { diagnostic in diagnostics.mutate { $0.append(diagnostic) } }, logLevel: .debug))
        for name in ["first", "failing", "last"] {
            _ = errors.addModule(.init(name: name, close: {
                closed.mutate { $0.append(name) }
                if name == "failing" { throw MessagevisorError("canonical close failure") }
            }))
        }
        do { try await errors.close(); XCTFail("Expected close failure") }
        catch let aggregate as MessagevisorCloseError { XCTAssertEqual(aggregate.errors.count, 1) }
        XCTAssertEqual(contract["closeOrder"] as? String, "reverse")
        XCTAssertEqual(closed.value, ["removed", "last", "failing", "first"])
        let failure = try XCTUnwrap(diagnostics.value.first { $0.code == contract["closeFailureCode"] as? String })
        XCTAssertEqual(failure.moduleName, "failing")
        XCTAssertEqual(failure.originalError, "canonical close failure")
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
        XCTAssertEqual(try formatted.formatNumber(1, preset: "missing"), try formatted.formatNumber(1))
        XCTAssertThrowsError(try formatted.formatNumber(1, formatOptions: ["style": .string("currency"), "currency": .string("INVALID")]))
        let codes = Set(diagnostics.value.map(\.code))
        XCTAssertTrue(codes.contains(diagnosticsContract["missingLocaleDatafileCode"] as! String))
        XCTAssertTrue(codes.contains(diagnosticsContract["missingFormatCode"] as! String))
        XCTAssertTrue(codes.contains(diagnosticsContract["invalidFormatCode"] as! String))
        _ = formatted.addModule(.init(name: "details", setup: { api in
            api.reportDiagnostic(.init(level: .info, code: "no_details", message: "No explicit details"))
        }))
        let withoutDetails = try XCTUnwrap(diagnostics.value.first { $0.code == "no_details" })
        XCTAssertEqual(diagnosticsContract["detailsAlwaysPresent"] as? Bool, true)
        XCTAssertEqual(withoutDetails.details, [:])
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
        // This is an immutable event captured before close, not the child's live snapshot.
        XCTAssertEqual(trace.value.first?["datafileRevision"] as? String, events["capturedChildDatafileRevisionAfterClose"] as? String)
        // Closing stops subscriptions, not shared data storage. This read is deliberately
        // testing the distinction, not encouraging application use after close.
        XCTAssertEqual(child.getSnapshot().datafileRevisionsByLocale["en"], afterClose.revision)
        XCTAssertEqual(child.getSnapshot().version, 1)
    }

    func testHardeningFormatMerge() throws {
        let hardening = try XCTUnwrap(fixture["hardening"] as? [String: Any])
        let contract = hardening["formatMerge"] as! [String: Any]
        var initial = try fixtureDatafile()
        initial.formats = try decode(FormatPresets.self, contract["initial"]!)
        let sdk = createMessagevisor(.init(datafile: initial, logLevel: .fatal))
        let child = sdk.spawn()
        var incoming = initial
        incoming.formats = try decode(FormatPresets.self, contract["incoming"]!)
        sdk.setDatafile(incoming)
        let expected = try decode(FormatPresets.self, contract["expected"]!)
        XCTAssertEqual(try sdk.getDatafile().formats, expected)
        XCTAssertEqual(try child.formatNumber(0.5, preset: "money"), "50%")
        incoming.formats = nil
        sdk.setDatafile(incoming)
        XCTAssertEqual(try sdk.getDatafile().formats, expected)
        sdk.setDatafile(incoming, replace: true)
        XCTAssertNil(try sdk.getDatafile().formats)
    }

    func testHardeningDatafileValidation() throws {
        let hardening = try XCTUnwrap(fixture["hardening"] as? [String: Any])
        let contract = hardening["datafileValidation"] as! [String: Any]
        let initial = try fixtureDatafile()
        let object = try JSONSerialization.jsonObject(with: Data(initial.toJSON().utf8)) as! [String: Any]
        var invalid = contract["invalidInputs"] as! [Any]
        for item in contract["invalidFields"] as! [[String: Any]] {
            var changed = object; changed[item["field"] as! String] = item["value"]!
            invalid.append(changed)
        }
        for field in (contract["requiredStrings"] as! [String]) + (contract["requiredMaps"] as! [String]) {
            var changed = object; changed.removeValue(forKey: field); invalid.append(changed)
        }
        for input in invalid {
            let diagnostics = ConcurrencyBox<[MessagevisorDiagnostic]>([])
            let errors = ConcurrencyBox<Int>(0), changes = ConcurrencyBox<Int>(0)
            let sdk = createMessagevisor(.init(datafile: initial, onDiagnostic: { d in diagnostics.mutate { $0.append(d) } }, logLevel: .debug))
            _ = sdk.on(.error) { _ in errors.mutate { $0 += 1 } }
            _ = sdk.subscribe { changes.mutate { $0 += 1 } }
            let snapshot = sdk.getSnapshot()
            let json = try input as? String ?? String(decoding: JSONSerialization.data(withJSONObject: input, options: [.fragmentsAllowed]), as: UTF8.self)
            sdk.setDatafile(json)
            XCTAssertEqual(sdk.getSnapshot(), snapshot, json)
            XCTAssertEqual(try sdk.getDatafile(), initial)
            XCTAssertEqual(errors.value, 1, json)
            XCTAssertEqual(changes.value, 0)
            XCTAssertEqual(diagnostics.value.last?.code, contract["code"] as? String)
            XCTAssertEqual(diagnostics.value.last?.message, contract["message"] as? String)
        }
        let valid = DatafileContent(messagevisorVersion: "", revision: "", target: "", locale: "en")
        XCTAssertEqual(try DatafileContent.fromJSON(valid.toJSON()), valid)
        let sdk = createMessagevisor(.init(datafile: initial, logLevel: .fatal))
        for invalid in [DatafileContent(schemaVersion: "2", locale: "en"), DatafileContent(locale: ""), DatafileContent(locale: "en", direction: "wrong")] {
            sdk.setDatafile(invalid)
            XCTAssertEqual(try sdk.getDatafile(), initial)
        }
    }

    func testHardeningReservedDictionaryKeys() throws {
        let hardening = try XCTUnwrap(fixture["hardening"] as? [String: Any])
        for key in hardening["dictionaryKeys"] as! [String] {
            var datafile = try fixtureDatafile()
            let sdk = createMessagevisor(.init(datafile: datafile, logLevel: .fatal))
            XCTAssertEqual(try sdk.translate(key), key)
            XCTAssertThrowsError(try sdk.getDatafile(locale: key))
            XCTAssertFalse(evaluateSegment(key, provider: .init()))
            XCTAssertFalse(evaluateCondition(.predicate(.init(attribute: key, operator: "exists")), provider: .init()))
            XCTAssertFalse(evaluateCondition(.predicate(.init(attribute: "nested.\(key)", operator: "exists")), provider: .init(context: ["nested": .object([:])])))
            XCTAssertTrue(evaluateCondition(.predicate(.init(attribute: "nested.\(key)", operator: "equals", value: .string("own"))), provider: .init(context: ["nested": .object([key: .string("own")])])) )
            XCTAssertTrue(evaluateSegment(key, provider: .init(segments: [key: .init(conditions: .all)])))
            datafile.messages[key] = .init(); datafile.translations[key] = "own"
            datafile.formats = .init(number: [key: ["style": .string("percent")]])
            sdk.setDatafile(try datafile.toJSON())
            XCTAssertEqual(try sdk.translate(key), "own")
            XCTAssertEqual(try sdk.formatNumber(0.5, preset: key), "50%")
            datafile.locale = key; sdk.setDatafile(datafile)
            XCTAssertEqual(sdk.getSnapshot().datafileRevisionsByLocale[key], datafile.revision)
            let defaults = createMessagevisor(.init(locale: key, defaultTranslations: [key: [key: "default"]], defaultFormats: [key: datafile.formats!], logLevel: .fatal))
            XCTAssertEqual(try defaults.translate(key), "default")
            XCTAssertEqual(defaults.getDefaultFormats()?.number?[key], ["style": .string("percent")])
        }
    }

    func testHardeningModuleSetupAndErrors() throws {
        let hardening = try XCTUnwrap(fixture["hardening"] as? [String: Any])
        let contract = hardening["moduleSetup"] as! [String: Any]
        var initial = try fixtureDatafile(); initial.revision = contract["initialRevision"] as! String
        let trace = ConcurrencyBox<[String]>([])
        let module = MessagevisorModule(name: "ready", setup: { api in
            let revision = try api.getRevision(nil)
            trace.mutate { $0.append(revision) }
            _ = api.onDiagnostic({ d in trace.mutate { $0.append(d.code) } }, .init())
        })
        let sdk = createMessagevisor(.init(datafile: initial, locale: "other", defaultTranslations: [initial.locale: ["ready": "Ready"]], logLevel: .fatal, modules: [module]))
        XCTAssertEqual(trace.value, [initial.revision, "sdk_initialized"])
        XCTAssertEqual(sdk.getLocale(), initial.locale)
        XCTAssertEqual(try sdk.translate("ready"), "Ready")
        final class OriginalError: Error, @unchecked Sendable {}
        for hook in ["format", "transform"] {
            let original = OriginalError()
            let diagnostics = ConcurrencyBox<[MessagevisorDiagnostic]>([]), events = ConcurrencyBox<Int>(0)
            var broken = MessagevisorModule(name: "broken")
            if hook == "format" { broken.format = { _, _ in throw original } }
            else { broken.transform = { _, _ in throw original } }
            let sdk = createMessagevisor(.init(datafile: initial, onDiagnostic: { d in diagnostics.mutate { $0.append(d) } }, logLevel: .debug, modules: [broken]))
            _ = sdk.on(.error) { _ in events.mutate { $0 += 1 } }
            let child = sdk.spawn(options: .init(locale: "nl"))
            let childEvents = ConcurrencyBox<Int>(0)
            _ = child.on(.error) { _ in childEvents.mutate { $0 += 1 } }
            XCTAssertThrowsError(try child.formatMessage("message")) { XCTAssertTrue(($0 as? OriginalError) === original) }
            XCTAssertEqual(events.value, 0); XCTAssertEqual(childEvents.value, 1)
            let diagnostic = try XCTUnwrap(diagnostics.value.last)
            XCTAssertEqual(diagnostic.code, contract["\(hook)FailureCode"] as? String)
            XCTAssertEqual(diagnostic.moduleName, "broken")
            XCTAssertEqual(diagnostic.details["hook"], .string(hook))
            XCTAssertEqual(diagnostic.details["locale"], .string("nl"))
            XCTAssertEqual(diagnostic.details["source"], .string("formatMessage"))
            XCTAssertNotNil(diagnostic.originalError)
        }
    }

    func testHardeningErrorEventsAndListParts() throws {
        let hardening = try XCTUnwrap(fixture["hardening"] as? [String: Any])
        let contract = hardening["errors"] as! [String: Any]
        let diagnostics = ConcurrencyBox<[MessagevisorDiagnostic]>([]), events = ConcurrencyBox<Int>(0)
        let sdk = createMessagevisor(.init(datafile: try fixtureDatafile(), onDiagnostic: { d in diagnostics.mutate { $0.append(d) } }, logLevel: .debug))
        _ = sdk.on(.error) { _ in events.mutate { $0 += 1 } }
        let snapshot = sdk.getSnapshot()
        XCTAssertThrowsError(try sdk.setLocale("missing"))
        XCTAssertEqual(diagnostics.value.last?.code, contract["missingSetLocaleCode"] as? String)
        XCTAssertEqual(sdk.getSnapshot(), snapshot)
        let invalid = Date(timeIntervalSince1970: .nan)
        let calls: [() throws -> Void] = [
            { _ = try sdk.formatDate(invalid) }, { _ = try sdk.formatDateToParts(invalid) },
            { _ = try sdk.formatTime(invalid) }, { _ = try sdk.formatTimeToParts(invalid) },
            { _ = try sdk.formatDateTimeRange(invalid, Date()) },
            { _ = try sdk.formatRelativeTime(.infinity, unit: .day) }
        ]
        for (index, call) in calls.enumerated() {
            XCTAssertThrowsError(try call())
            XCTAssertEqual(events.value, index + 2)
            XCTAssertEqual(diagnostics.value.last?.code, contract["invalidFormatterValueCode"] as? String)
        }
        let fallback = hardening["fallbacks"] as! [String: Any]
        for input in [fallback["listInput"] as! [String], [], ["A"]] {
            XCTAssertEqual(try sdk.formatListToParts(input), [.init(type: "literal", value: try sdk.formatList(input))])
            XCTAssertEqual(diagnostics.value.last?.code, fallback["diagnosticCode"] as? String)
        }
    }

    func testHardeningTimeZonesAndNativeICUParity() throws {
        let hardening = try XCTUnwrap(fixture["hardening"] as? [String: Any])
        let zone = hardening["timeZones"] as! [String: Any]
        let instant = try XCTUnwrap(MessagevisorValue.string(zone["instant"] as! String).dateValue)
        let instanceZone = zone["instance"] as! String, presetZone = zone["preset"] as! String, callZone = zone["call"] as! String
        let formats = FormatPresets(
            date: ["selected": ["year": .string("numeric"), "month": .string("2-digit"), "day": .string("2-digit"), "timeZone": .string(presetZone)]],
            time: ["selected": ["hour": .string("numeric"), "minute": .string("numeric"), "timeZone": .string(presetZone)]],
            dateTimeRange: ["selected": ["dateStyle": .string("short"), "timeStyle": .string("short"), "timeZone": .string(presetZone)]]
        )
        let sdk = createMessagevisor(.init(locale: "en-GB", timeZone: instanceZone, defaultFormats: ["en-GB": formats, "en-US": formats], logLevel: .fatal, modules: [createICUModule()]))
        let child = sdk.spawn(options: .init(timeZone: callZone))
        for locale in ["en-GB", "en-US"] {
            for call in [nil, callZone] {
                let options = EvaluationOptions(locale: locale, timeZone: call)
                for preset in [nil, "selected"] {
                    let suffix = preset.map { ", \($0)" } ?? ""
                    let values: MessagevisorValues = ["d": .date(instant)]
                    XCTAssertEqual(try sdk.formatMessage("{d, date\(suffix)}", values: values, options: options), try sdk.formatDate(instant, preset: preset, options: options))
                    XCTAssertEqual(try sdk.formatMessage("{d, time\(suffix)}", values: values, options: options), try sdk.formatTime(instant, preset: preset, options: options))
                    XCTAssertEqual(try child.formatMessage("{d, date\(suffix)}", values: values, options: options), try child.formatDate(instant, preset: preset, options: options))
                    XCTAssertEqual(try child.formatMessage("{d, time\(suffix)}", values: values, options: options), try child.formatTime(instant, preset: preset, options: options))
                }
                let native = DateIntervalFormatter(); native.locale = Locale(identifier: locale)
                native.timeZone = TimeZone(identifier: call ?? presetZone); native.dateStyle = .short; native.timeStyle = .short
                let end = instant.addingTimeInterval(3600)
                XCTAssertEqual(try sdk.formatDateTimeRange(instant, end, preset: "selected", options: options), native.string(from: instant, to: end))
                XCTAssertEqual(try child.formatDateTimeRange(instant, end, preset: "selected", options: options), native.string(from: instant, to: end))
                let nativeDate = DateFormatter(); nativeDate.locale = Locale(identifier: locale)
                nativeDate.timeZone = TimeZone(identifier: call ?? instanceZone)
                nativeDate.setLocalizedDateFormatFromTemplate("yyyyMMdd")
                XCTAssertEqual(try sdk.formatMessage("{d, date, ::yyyyMMdd}", values: ["d": .date(instant)], options: options), nativeDate.string(from: instant))
                nativeDate.dateStyle = .none; nativeDate.timeStyle = .short
                XCTAssertEqual(try sdk.formatMessage("{d, time, short}", values: ["d": .date(instant)], options: options), nativeDate.string(from: instant))
            }
        }
        XCTAssertNotEqual(try sdk.formatDate(instant), try sdk.formatDate(instant, options: .init(timeZone: presetZone)))
        XCTAssertEqual(sdk.getTimeZone(), instanceZone); XCTAssertEqual(child.getTimeZone(), callZone)
        let host = createMessagevisor(.init(locale: "en-GB", logLevel: .fatal, modules: [createICUModule()]))
        let hostChild = host.spawn()
        XCTAssertEqual(try host.formatTime(instant), try hostChild.formatTime(instant))
        XCTAssertEqual(try host.formatTime(instant), try host.formatMessage("{d, time}", values: ["d": .date(instant)]))
        for timestamp in ["2026-03-29T00:30:00Z", "2026-03-29T01:30:00Z"] {
            let date = try XCTUnwrap(MessagevisorValue.string(timestamp).dateValue)
            let options = EvaluationOptions(timeZone: "Europe/Amsterdam")
            XCTAssertEqual(try sdk.formatTime(date, options: options), try sdk.formatMessage("{d, time}", values: ["d": .date(date)], options: options))
        }
        sdk.setTimeZone(presetZone)
        XCTAssertEqual(try sdk.formatDate(instant), try sdk.formatDate(instant, options: .init(timeZone: presetZone)))
        XCTAssertEqual(child.getTimeZone(), callZone)
        for key in hardening["dictionaryKeys"] as! [String] {
            let options = EvaluationOptions(formats: .init(number: [key: ["style": .string("percent")]]))
            XCTAssertEqual(try sdk.formatMessage("{n, number, \(key)}", values: ["n": .double(0.5)], options: options), "50%")
            XCTAssertEqual(try sdk.formatMessage("{\(key)}", values: [key: .string("own")]), "own")
            XCTAssertThrowsError(try sdk.formatMessage("{\(key)}"))
            XCTAssertEqual(try sdk.formatMessage("{x, select, other {safe}}", values: ["x": .string(key)]), "safe")
        }
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
