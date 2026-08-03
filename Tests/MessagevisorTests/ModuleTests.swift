import XCTest
import Dispatch
@testable import Messagevisor

final class ModuleTests: XCTestCase {
    func testSetupResolversDiagnosticsRemovalAndDuplicates() async throws {
        let diagnostics = ConcurrencyBox<[String]>([]), closes = ConcurrencyBox(0)
        let module = MessagevisorModule(name: "feature", setup: { api in
            api.setFlagResolver { key, _ in key == "enabled" }
            api.reportDiagnostic(.init(level: .warn, code: "module_ready", message: "ready"))
        }, close: { closes.mutate { $0 += 1 } })
        let condition = Condition.predicate(.init(feature: "enabled", operator: "isEnabled"))
        let datafile = DatafileContent(messagevisorVersion: "test", target: "swift", locale: "en", messages: ["key": .init(overrides: [.init(key: "flag", conditions: condition, translation: "On")])], translations: ["key": "Off"])
        let sdk = createMessagevisor(.init(datafile: datafile, onDiagnostic: { diagnostic in diagnostics.mutate { $0.append(diagnostic.code) } }, logLevel: .debug))
        let remove = sdk.addModule(module)
        XCTAssertEqual(try sdk.translate("key"), "On")
        _ = sdk.addModule(MessagevisorModule(name: "feature"))
        XCTAssertTrue(diagnostics.value.contains("duplicate_module"))
        try await remove(); try await remove(); XCTAssertEqual(closes.value, 1)
        XCTAssertEqual(try sdk.translate("key"), "Off")
    }

    func testSetupFailureRollsBackAndCloseContinuesInReverseOrder() async {
        let order = ConcurrencyBox<[String]>([]), diagnostics = ConcurrencyBox<[String]>([])
        let failed = MessagevisorModule(name: "failed", setup: { api in api.setFlagResolver { _, _ in true }; throw MessagevisorError("setup") }, close: { order.mutate { $0.append("failed") } })
        let first = MessagevisorModule(name: "first", close: { order.mutate { $0.append("first") } })
        let second = MessagevisorModule(name: "second", close: { order.mutate { $0.append("second") }; throw MessagevisorError("close") })
        let sdk = createMessagevisor(.init(onDiagnostic: { diagnostic in diagnostics.mutate { $0.append(diagnostic.code) } }, logLevel: .debug, modules: [failed, first, second]))
        do { try await sdk.close(); XCTFail("Expected aggregate error") } catch let error as MessagevisorCloseError { XCTAssertEqual(error.errors.count, 1) } catch { XCTFail("Unexpected \(error)") }
        XCTAssertEqual(order.value, ["failed", "second", "first"])
        XCTAssertTrue(diagnostics.value.contains("module_setup_error")); XCTAssertTrue(diagnostics.value.contains("module_close_error"))
    }

    func testModuleDiagnosticSubscriptionDoesNotReceiveItsOwnReports() async throws {
        let observed = ConcurrencyBox<[String]>([])
        let module = MessagevisorModule(name: "observer", setup: { api in
            _ = api.onDiagnostic({ diagnostic in observed.mutate { $0.append(diagnostic.code) } }, .init(logLevel: .debug))
            api.reportDiagnostic(.init(level: .warn, code: "self", message: "self"))
        })
        let sdk = createMessagevisor(.init(locale: "en", logLevel: .fatal, modules: [module]))
        _ = try sdk.translate("missing")
        XCTAssertFalse(observed.value.contains("self")); XCTAssertTrue(observed.value.contains("missing_datafile"))
        try await sdk.close()
    }

    func testNilModuleResultsPreserveCurrentTranslationAndPayloadIsComplete() throws {
        let formatSource = ConcurrencyBox<MessagevisorTranslationSource?>(nil)
        let transformKey = ConcurrencyBox<String?>(nil)
        let locale = ConcurrencyBox<String?>(nil)
        let observer = MessagevisorModule(name: "observer", format: { payload, _ in
            formatSource.mutate { $0 = payload.source }; locale.mutate { $0 = payload.locale }
            return nil
        }, transform: { payload, _ in
            transformKey.mutate { $0 = payload.messageKey }
            return nil
        })
        let sdk = createMessagevisor(.init(datafile: .init(messagevisorVersion: "test", target: "swift", locale: "en", messages: ["welcome": .init()], translations: ["welcome": "Hello"]), modules: [observer]))
        XCTAssertEqual(try sdk.translate("welcome"), "Hello")
        XCTAssertEqual(formatSource.value, .translation)
        XCTAssertEqual(transformKey.value, "welcome")
        XCTAssertEqual(locale.value, "en")
    }

    func testRepeatedCloseAwaitsOneCleanupAndReturnsTheSameFailure() async {
        let closes = ConcurrencyBox(0)
        let module = MessagevisorModule(name: "failing", close: {
            closes.mutate { $0 += 1 }
            throw MessagevisorError("close")
        })
        let sdk = createMessagevisor(.init(logLevel: .fatal, modules: [module]))

        for _ in 0..<2 {
            do {
                try await sdk.close()
                XCTFail("Expected aggregate error")
            } catch let error as MessagevisorCloseError {
                XCTAssertEqual(error.errors.count, 1)
            } catch {
                XCTFail("Unexpected \(error)")
            }
        }

        XCTAssertEqual(closes.value, 1)
    }

    func testRetainedModuleDiagnosticApisAreSafeAcrossConcurrentCallers() async throws {
        let observerApi = ConcurrencyBox<MessagevisorModuleApi?>(nil)
        let reporterApi = ConcurrencyBox<MessagevisorModuleApi?>(nil)
        let observed = ConcurrencyBox(0)
        let observer = MessagevisorModule(name: "observer", setup: { api in
            observerApi.mutate { $0 = api }
            _ = api.onDiagnostic({ _ in observed.mutate { $0 += 1 } }, .init(logLevel: .debug))
        })
        let reporter = MessagevisorModule(name: "reporter", setup: { api in
            reporterApi.mutate { $0 = api }
        })
        let sdk = createMessagevisor(.init(logLevel: .fatal, modules: [observer, reporter]))
        let observerValue = try XCTUnwrap(observerApi.value)
        let reporterValue = try XCTUnwrap(reporterApi.value)
        let initialObserved = observed.value

        DispatchQueue.concurrentPerform(iterations: 500) { index in
            if index.isMultiple(of: 2) {
                let unsubscribe = observerValue.onDiagnostic({ _ in }, .init(logLevel: .debug))
                unsubscribe()
            } else {
                reporterValue.reportDiagnostic(.init(level: .info, code: "concurrent", message: "Concurrent diagnostic"))
            }
        }

        XCTAssertEqual(observed.value, initialObserved + 250)
        try await sdk.close()
    }

    func testSdkErrorsHaveUsefulLocalizedDescriptions() {
        let error = MessagevisorError("Useful failure")
        XCTAssertEqual(error.localizedDescription, "Useful failure")

        let closeError = MessagevisorCloseError(errors: [error])
        XCTAssertEqual(closeError.localizedDescription, "One or more Messagevisor modules failed to close.")
    }
}
