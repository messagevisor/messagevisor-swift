import XCTest
import Dispatch
@testable import Messagevisor

final class RuntimeTests: XCTestCase {
    private func datafile(locale: String = "en", revision: String = "1", translation: String = "Hello") -> DatafileContent {
        .init(messagevisorVersion: "test", revision: revision, target: "swift", locale: locale, direction: "ltr", segments: [:], messages: ["welcome": .init(meta: ["area": .string("home")])], translations: ["welcome": translation])
    }

    func testDatafilesMergeReplaceAndLocaleSelection() throws {
        let sdk = createMessagevisor(.init(datafile: datafile()))
        sdk.setDatafile(.init(messagevisorVersion: "test", revision: "2", target: "other", locale: "en", segments: [:], messages: [:], translations: ["second": "Second"]))
        XCTAssertEqual(try sdk.getRawTranslation("welcome"), "Hello")
        XCTAssertEqual(try sdk.getRawTranslation("second"), "Second")
        XCTAssertEqual(try sdk.getRevision(), "2")
        sdk.setDatafile(datafile(locale: "nl", translation: "Hallo"))
        XCTAssertEqual(sdk.getLocale(), "en")
        try sdk.setLocale("nl"); XCTAssertEqual(try sdk.translate("welcome"), "Hallo")
        sdk.setDatafile(.init(messagevisorVersion: "test", revision: "3", target: "swift", locale: "nl", segments: [:], messages: [:], translations: ["fresh": "Vers"]), replace: true)
        XCTAssertEqual(try sdk.getRawTranslation("welcome"), "welcome")
        XCTAssertEqual(try sdk.getRawTranslation("fresh"), "Vers")
    }

    func testInvalidDatafileAndFallbackOrder() throws {
        let diagnostics = ConcurrencyBox<[MessagevisorDiagnostic]>([])
        let sdk = createMessagevisor(.init(locale: "en", defaultTranslations: ["en": ["configured": "Configured", "empty": ""]], onDiagnostic: { diagnostic in diagnostics.mutate { $0.append(diagnostic) } }, logLevel: .debug))
        sdk.setDatafile("not json")
        XCTAssertEqual(diagnostics.value.last?.code, "invalid_datafile")
        XCTAssertEqual(diagnostics.value.last?.message, "could not parse datafile")
        XCTAssertEqual(try sdk.translate("configured", options: .init(defaultTranslation: "Call")), "Configured")
        XCTAssertEqual(try sdk.translate("empty"), "")
        XCTAssertEqual(try sdk.translate("missing", options: .init(defaultTranslation: "Call")), "Call")
        XCTAssertEqual(try sdk.translate("last"), "last")
        XCTAssertEqual(sdk.getDefaultTranslations()?["configured"], "Configured")
        XCTAssertNil(sdk.getDefaultTranslations(locale: "nl"))
        XCTAssertTrue(diagnostics.value.allSatisfy { _ in true })
    }

    func testDirectionIsNilBeforeLocaleIsAvailable() throws {
        let diagnostics = ConcurrencyBox<[String]>([])
        let sdk = createMessagevisor(.init(
            onDiagnostic: { diagnostic in diagnostics.mutate { $0.append(diagnostic.code) } },
            logLevel: .debug
        ))

        XCTAssertNil(try sdk.getDirection())
        XCTAssertFalse(diagnostics.value.contains("missing_locale"))
        XCTAssertThrowsError(try sdk.getDirection(locale: "missing"))
        XCTAssertTrue(diagnostics.value.contains("missing_datafile"))
    }

    func testOverridesContextAndPerCallLocale() throws {
        let message = DatafileMessage(deprecated: true, deprecationWarning: "Use new", meta: ["owner": .string("checkout")], overrides: [
            .init(key: "pro-web", conditions: .predicate(.init(attribute: "plan", operator: "equals", value: .string("pro"))), segments: .key("web"), translation: "Pro")
        ])
        let en = DatafileContent(messagevisorVersion: "test", target: "swift", locale: "en", segments: ["web": .init(conditions: .predicate(.init(attribute: "platform", operator: "equals", value: .string("web"))))], messages: ["welcome": message], translations: ["welcome": "Base"])
        let nl = DatafileContent(messagevisorVersion: "test", target: "swift", locale: "nl", segments: [:], messages: [:], translations: ["welcome": "Hallo"])
        let codes = ConcurrencyBox<[String]>([])
        let sdk = createMessagevisor(.init(datafile: en, context: ["platform": .string("web")], onDiagnostic: { diagnostic in codes.mutate { $0.append(diagnostic.code) } }, logLevel: .debug))
        sdk.setDatafile(nl)
        XCTAssertEqual(try sdk.translate("welcome", options: .init(context: ["plan": .string("pro")])), "Pro")
        XCTAssertEqual(try sdk.translate("welcome", options: .init(locale: "nl")), "Hallo")
        XCTAssertEqual(sdk.getLocale(), "en")
        XCTAssertTrue(codes.value.contains("message_override_matched")); XCTAssertTrue(codes.value.contains("deprecated_message"))
    }

    func testEventsSnapshotsAndObserverIsolation() throws {
        let sdk = createMessagevisor(.init(locale: "en", logLevel: .fatal))
        let order = ConcurrencyBox<[String]>([])
        _ = sdk.on(.contextSet) { event in order.mutate { $0.append(event.type.rawValue) }; throw MessagevisorError("observer") }
        _ = sdk.on(.contextSet) { event in
            order.mutate { $0.append("second") }
            if case .contextSet(_, _, let replaced) = event.details { XCTAssertFalse(replaced) } else { XCTFail() }
        }
        _ = sdk.on(.change) { event in
            if case .change(let source, _) = event.details { order.mutate { $0.append("change:\(source.rawValue)") } }
        }
        sdk.setContext(["plan": .string("pro")])
        XCTAssertEqual(order.value, ["context_set", "second", "change:context_set"])
        XCTAssertEqual(sdk.getSnapshot().version, 1)
        XCTAssertEqual(sdk.getSnapshot().context["plan"], .string("pro"))
    }

    func testSpawnSharesDataAndModulesButIsolatesState() throws {
        let upper = MessagevisorModule(name: "upper", transform: { payload, _ in payload.translation.uppercased() })
        let defaults = FormatPresets(number: ["money": ["style": .string("currency")]])
        let sdk = createMessagevisor(.init(datafile: datafile(), context: ["root": .bool(true)], defaultFormats: ["en": defaults], modules: [upper]))
        let child = sdk.spawn(context: ["request": .string("1")], options: .init(locale: "en", currency: "EUR"))
        XCTAssertEqual(try child.translate("welcome"), "HELLO")
        XCTAssertEqual(child.getDefaultFormats()?.number?["money"]?["style"], .string("currency"))
        XCTAssertEqual(child.getContext()["root"], .bool(true)); XCTAssertNil(sdk.getContext()["request"])
        sdk.setDatafile(.init(messagevisorVersion: "test", revision: "2", target: "swift", locale: "en", segments: [:], messages: [:], translations: ["later": "Later"]))
        XCTAssertEqual(try child.translate("later"), "LATER")
    }

    func testChildHasIndependentEventsAndCanCloseWithoutClosingParent() async throws {
        let sdk = createMessagevisor(.init(datafile: datafile(), logLevel: .fatal))
        let child: MessagevisorChild = sdk.spawn(context: ["request": .string("one")])
        let parentChanges = ConcurrencyBox(0), childChanges = ConcurrencyBox(0)
        _ = sdk.subscribe { parentChanges.mutate { $0 += 1 } }
        _ = child.subscribe { childChanges.mutate { $0 += 1 } }

        child.setContext(["request": .string("two")])
        XCTAssertEqual(parentChanges.value, 0)
        XCTAssertEqual(childChanges.value, 1)
        let revisions = ConcurrencyBox<[String]>([])
        _ = child.on(.datafileSet) { event in
            if case .datafileSet(let datafile, _, _, _, _) = event.details {
                revisions.mutate { $0.append(datafile.revision) }
                XCTAssertEqual(event.snapshot.context["request"], .string("two"))
                XCTAssertEqual(event.snapshot.version, 2)
                XCTAssertEqual(event.previousSnapshot.version, 1)
            }
        }
        var updated = datafile(); updated.revision = "2"; sdk.setDatafile(updated, replace: true)
        XCTAssertEqual(revisions.value, ["2"])
        XCTAssertEqual(childChanges.value, 2)
        try await child.close()
        updated.revision = "3"; sdk.setDatafile(updated, replace: true)
        XCTAssertEqual(revisions.value, ["2"])
        XCTAssertEqual(childChanges.value, 2)
        XCTAssertEqual(try sdk.translate("welcome"), "Hello")
    }

    func testErrorDiagnosticEmitsErrorEventEvenWhenFilteredFromHandler() throws {
        let sdk = createMessagevisor(.init(locale: "en", logLevel: .fatal))
        let codes = ConcurrencyBox<[String]>([])
        _ = sdk.on(.error) { event in
            if case .error(let diagnostic) = event.details { codes.mutate { $0.append(diagnostic.code) } }
        }
        _ = try sdk.translate("missing")
        XCTAssertEqual(codes.value, ["missing_datafile"])
    }

    func testConcurrentEvaluationAndStateUpdatesAreSafe() {
        let base = datafile()
        let sdk = createMessagevisor(.init(datafile: base, logLevel: .fatal))
        let child = sdk.spawn(context: ["request": .string("child")])
        let failures = ConcurrencyBox<[String]>([])

        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            if index.isMultiple(of: 10) {
                sdk.setContext(["iteration": .int(index)])
                var next = base
                next.revision = "\(index)"
                sdk.setDatafile(next, replace: true)
            } else {
                do {
                    if try sdk.translate("welcome") != "Hello" { failures.mutate { $0.append("root") } }
                    if try child.translate("welcome") != "Hello" { failures.mutate { $0.append("child") } }
                    if try sdk.formatNumber(Double(index), options: .init(locale: "en")).isEmpty { failures.mutate { $0.append("format") } }
                } catch {
                    failures.mutate { $0.append(error.localizedDescription) }
                }
            }
        }

        XCTAssertTrue(failures.value.isEmpty)
    }

    func testConcurrentEventSubscriptionAndDeliveryAreSafe() {
        let sdk = createMessagevisor(.init(locale: "en", logLevel: .fatal))
        let delivered = ConcurrencyBox(0)

        DispatchQueue.concurrentPerform(iterations: 500) { index in
            let unsubscribe = sdk.on(.contextSet) { _ in delivered.mutate { $0 += 1 } }
            sdk.setContext(["iteration": .int(index)])
            unsubscribe()
        }

        XCTAssertGreaterThan(delivered.value, 0)
    }
}
