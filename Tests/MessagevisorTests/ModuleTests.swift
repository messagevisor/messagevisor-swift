import XCTest
import Dispatch
@testable import Messagevisor

final class ModuleTests: XCTestCase {
    func testSetupFailureObserverCloseWaitsForAlreadyRegisteredCleanup() async throws {
        let gate = CleanupGate()
        let cleanupEntered = expectation(description: "Failed setup cleanup entered")
        let observerEntered = expectation(description: "Diagnostic observer requests close")
        let owner = ConcurrencyBox<Messagevisor?>(nil)
        let observerTask = ConcurrencyBox<Task<Void, Error>?>(nil)
        let cleanupFinished = ConcurrencyBox(false), closeFinished = ConcurrencyBox(false)
        let sdk = createMessagevisor(.init(onDiagnostic: { diagnostic in
            if diagnostic.code == "module_setup_error", let sdk = owner.value {
                observerTask.mutate { $0 = Task {
                    observerEntered.fulfill()
                    try await sdk.close()
                    closeFinished.mutate { $0 = true }
                } }
            }
        }, logLevel: .debug))
        owner.mutate { $0 = sdk }
        _ = sdk.addModule(.init(name: "failed", setup: { _ in throw MessagevisorError("setup") }, close: {
            cleanupEntered.fulfill()
            await gate.wait()
            cleanupFinished.mutate { $0 = true }
        }))
        await fulfillment(of: [cleanupEntered, observerEntered], timeout: 3)
        XCTAssertFalse(cleanupFinished.value)
        XCTAssertFalse(closeFinished.value)
        await gate.release()
        try await XCTUnwrap(observerTask.value).value
        XCTAssertTrue(cleanupFinished.value)
        XCTAssertTrue(closeFinished.value)
    }

    func testReentrantAndConcurrentCloseRequestsShareCompletionAndFailure() async throws {
        let gate = CleanupGate()
        let callbackEntered = expectation(description: "Module close callback")
        let nestedEntered = expectation(description: "Callback requests another close")
        let concurrentEntered = expectation(description: "Independent close request")
        let owner = ConcurrencyBox<Messagevisor?>(nil)
        let nestedTask = ConcurrencyBox<Task<Void, Error>?>(nil)
        let closes = ConcurrencyBox(0), finished = ConcurrencyBox(0)
        let sdk = createMessagevisor(.init(logLevel: .fatal))
        owner.mutate { $0 = sdk }
        _ = sdk.addModule(.init(name: "reentrant", close: {
            closes.mutate { $0 += 1 }
            nestedTask.mutate { $0 = Task {
                nestedEntered.fulfill()
                defer { finished.mutate { $0 += 1 } }
                try await owner.value?.close()
            } }
            callbackEntered.fulfill()
            // The callback must not await its own enclosing cleanup operation.
            await gate.wait()
            throw MessagevisorError("shared close failure")
        }))
        let first = Task { try await sdk.close() }
        await fulfillment(of: [callbackEntered, nestedEntered], timeout: 3)
        let second = Task {
            concurrentEntered.fulfill()
            defer { finished.mutate { $0 += 1 } }
            try await sdk.close()
        }
        await fulfillment(of: [concurrentEntered], timeout: 3)
        XCTAssertEqual(finished.value, 0)
        XCTAssertEqual(closes.value, 1)
        await gate.release()
        for task in [first, second, try XCTUnwrap(nestedTask.value)] {
            do { try await task.value; XCTFail("Expected shared close failure") }
            catch let error as MessagevisorCloseError {
                XCTAssertEqual(error.errors.count, 1)
                XCTAssertEqual(error.errors.first?.localizedDescription, "shared close failure")
            }
        }
        XCTAssertEqual(finished.value, 2)
        XCTAssertEqual(closes.value, 1)
    }

    func testRemovingModuleClearsChildSubscriptionsAndRetainedApis() async throws {
        let retained = ConcurrencyBox<MessagevisorModuleApi?>(nil)
        let received = ConcurrencyBox(0)
        let sdk = createMessagevisor(.init(locale: "en", logLevel: .fatal))
        let module = MessagevisorModule(name: "observer", format: { _, api in
            retained.mutate { $0 = api }
            _ = api.onDiagnostic({ _ in received.mutate { $0 += 1 } }, .init(logLevel: .debug))
            return nil
        })
        let remove = sdk.addModule(module)
        let child = sdk.spawn()
        _ = try child.formatMessage("text")
        _ = try child.translate("missing")
        XCTAssertGreaterThan(received.value, 0)
        try await sdk.removeModule("observer")
        let baseline = received.value
        _ = retained.value?.onDiagnostic({ _ in received.mutate { $0 += 1 } }, .init(logLevel: .debug))
        retained.value?.reportDiagnostic(.init(level: .error, code: "late", message: "late"))
        _ = try child.translate("another-missing")
        XCTAssertEqual(received.value, baseline)
        try await remove()
        try await child.close()
        try await sdk.close()
    }

    func testRemovingModuleReleasesChildCapturedResourcesAndNameCanBeReused() async throws {
        let sdk = createMessagevisor(.init(locale: "en", logLevel: .fatal))
        let child = sdk.spawn()
        weak var weakResource: ConcurrencyBox<Int>?
        do {
            let resource = ConcurrencyBox(1); weakResource = resource
            _ = sdk.addModule(.init(name: "temporary", format: { _, api in
                _ = api.onDiagnostic({ _ in resource.mutate { $0 += 1 } }, .init())
                return nil
            }))
        }
        _ = try child.formatMessage("text")
        XCTAssertNotNil(weakResource)
        try await sdk.removeModule("temporary")
        XCTAssertNil(weakResource)
        _ = sdk.addModule(.init(name: "temporary", format: { _, _ in "replacement" }))
        XCTAssertEqual(try child.formatMessage("text"), "replacement")
        try await sdk.close()
    }

    func testRootCloseRemovesChildObserversButChildCloseDoesNotDisableRootModule() async throws {
        let rootApi = ConcurrencyBox<MessagevisorModuleApi?>(nil)
        let received = ConcurrencyBox(0)
        let sdk = createMessagevisor(.init(locale: "en", logLevel: .fatal, modules: [.init(name: "observer", setup: { api in rootApi.mutate { $0 = api } }, format: { _, api in
            _ = api.onDiagnostic({ _ in received.mutate { $0 += 1 } }, .init(logLevel: .debug))
            return nil
        })]))
        let first = sdk.spawn(), second = sdk.spawn()
        _ = try first.formatMessage("text"); _ = try second.formatMessage("text")
        try await first.close()
        _ = try sdk.formatMessage("root")
        let before = received.value
        _ = try sdk.translate("missing")
        XCTAssertGreaterThan(received.value, before)
        try await sdk.close()
        let after = received.value
        rootApi.value?.reportDiagnostic(.init(level: .error, code: "late", message: "late"))
        _ = try second.translate("missing")
        XCTAssertEqual(received.value, after)
    }

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

private actor CleanupGate {
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() {
        released = true
        let continuations = waiting; waiting.removeAll()
        continuations.forEach { $0.resume() }
    }
}
