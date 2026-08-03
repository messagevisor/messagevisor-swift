import XCTest
import Messagevisor
@testable import MessagevisorMissingTranslations

private final class MissingTranslationsTestBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: T
    init(_ value: T) { storedValue = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return storedValue }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; body(&storedValue) }
}

final class MissingTranslationsModuleTests: XCTestCase {
    func testReportsPayloadAndDeduplicatesPerRevision() throws {
        let payloads = MissingTranslationsTestBox<[MissingTranslationPayload]>([])
        let module = createMissingTranslationsModule(.init(dedupe: true) { payload in payloads.mutate { $0.append(payload) } })
        let datafile = DatafileContent(messagevisorVersion: "test", revision: "1", target: "swift", locale: "en")
        let sdk = createMessagevisor(.init(datafile: datafile, logLevel: .fatal, modules: [module]))
        _ = try sdk.translate("missing")
        _ = try sdk.translate("missing")
        XCTAssertEqual(payloads.value.count, 1)
        XCTAssertEqual(payloads.value[0].messageKey, "missing")
        XCTAssertEqual(payloads.value[0].locale, "en")
        XCTAssertEqual(payloads.value[0].revision, "1")
        XCTAssertEqual(payloads.value[0].source, .translation)

        sdk.setDatafile(.init(messagevisorVersion: "test", revision: "2", target: "swift", locale: "en"))
        _ = try sdk.translate("missing")
        XCTAssertEqual(payloads.value.count, 2)
    }
}
