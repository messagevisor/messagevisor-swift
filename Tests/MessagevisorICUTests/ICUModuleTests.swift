import XCTest
import Messagevisor
@testable import MessagevisorICU

private final class ICUTestBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: T
    init(_ value: T) { storedValue = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return storedValue }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; body(&storedValue) }
}

final class ICUModuleTests: XCTestCase {
    func testPluralAndSelect() throws {
        let sdk = createMessagevisor(.init(locale: "en", modules: [createICUModule()]))
        XCTAssertEqual(try sdk.formatMessage("{count, plural, =0 {None} one {# item} other {# items}}", values: ["count": .int(2)]), "2 items")
        XCTAssertEqual(try sdk.formatMessage("{gender, select, female {She} male {He} other {They}}", values: ["gender": .string("female")]), "She")
    }

    func testNestedOrdinalOffsetEscapingAndPortableDates() throws {
        let formats = FormatPresets(
            date: ["long": ["dateStyle": .string("long"), "timeZone": .string("UTC")]],
            time: ["short": ["hour": .string("2-digit"), "minute": .string("2-digit"), "timeZone": .string("UTC")]]
        )
        let sdk = createMessagevisor(.init(locale: "en-GB", defaultFormats: ["en-GB": formats], modules: [createICUModule()]))
        XCTAssertEqual(try sdk.formatMessage("{position, selectordinal, one {#st} two {#nd} few {#rd} other {#th}}", values: ["position": .int(22)]), "22nd")
        XCTAssertEqual(try sdk.formatMessage("{count, plural, offset:1 =0 {Nobody} one {{name} came alone} other {{name} and # others}}", values: ["count": .int(3), "name": .string("Ada")]), "Ada and 2 others")
        XCTAssertEqual(try sdk.formatMessage("This '{is}' quoted and ''this'' is not"), "This {is} quoted and 'this' is not")
        XCTAssertEqual(try sdk.formatMessage("{when, date, long}", values: ["when": .string("2026-11-26T15:05:00.123456Z")]), "26 November 2026")
        XCTAssertFalse(try sdk.formatMessage("{when, time, short}", values: ["when": .int(0)]).isEmpty)
    }

    func testPerCallModuleOptionsReportUnsupportedRichText() throws {
        let diagnostics = ICUTestBox<[String]>([])
        let sdk = createMessagevisor(.init(locale: "en", onDiagnostic: { diagnostic in diagnostics.mutate { $0.append(diagnostic.code) } }, logLevel: .debug, modules: [createICUModule()]))
        let options = EvaluationOptions(moduleOptions: ["icu": .object(["ignoreTags": .bool(false)])])
        XCTAssertEqual(try sdk.formatMessage("Read <b>this</b>", options: options), "Read <b>this</b>")
        XCTAssertTrue(diagnostics.value.contains("unsupported_formatter"))
    }

    func testInvalidFormatterOptionsEmitInvalidFormat() throws {
        let diagnostics = ICUTestBox<[String]>([])
        let formats = FormatPresets(number: ["broken": ["style": .string("currency"), "currency": .string("INVALID")]])
        let sdk = createMessagevisor(.init(locale: "en", defaultFormats: ["en": formats], onDiagnostic: { diagnostic in diagnostics.mutate { $0.append(diagnostic.code) } }, logLevel: .debug, modules: [createICUModule()]))

        XCTAssertThrowsError(try sdk.formatMessage("{amount, number, broken}", values: ["amount": .int(1)]))
        XCTAssertTrue(diagnostics.value.contains("invalid_format"))
    }
}
