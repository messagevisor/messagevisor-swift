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
    func testMissingValuesAreRejectedOnlyInSelectedUnquotedArguments() throws {
        let diagnostics = ICUTestBox<[String]>([])
        let sdk = createMessagevisor(.init(locale: "en", onDiagnostic: { event in diagnostics.mutate { $0.append(event.code) } }, logLevel: .debug, modules: [createICUModule()]))
        for expression in ["{x}", "{x, number}", "{x, number, integer}", "{x, date}", "{x, time, short}", "{x, select, yes {Yes} other {Other}}", "{x, plural, one {One} other {Other}}", "{x, selectordinal, other {Other}}"] {
            diagnostics.mutate { $0 = [] }
            XCTAssertThrowsError(try sdk.formatMessage(expression), expression)
            XCTAssertTrue(diagnostics.value.contains("invalid_message"), expression)
            XCTAssertEqual(try sdk.formatMessage("'\(expression)'"), expression)
            XCTAssertEqual(try sdk.formatMessage("{choice, select, yes {YES} other {\(expression)}}", values: ["choice": .string("yes")]), "YES")
            XCTAssertThrowsError(try sdk.formatMessage("{choice, select, yes {YES} other {\(expression)}}", values: ["choice": .string("other")]))
        }
        XCTAssertEqual(try sdk.formatMessage("'{quoted {d, date}}'"), "{quoted {d, date}}")
        XCTAssertEqual(try sdk.formatMessage("{kind, select, date {{d, date}} other {Safe}}", values: ["kind": .string("other"), "d": .string("invalid")]), "Safe")
    }

    func testNativeNumberStylesSkeletonsAndExplicitUnsupportedTokens() throws {
        let diagnostics = ICUTestBox<[String]>([])
        let sdk = createMessagevisor(.init(locale: "en-US", onDiagnostic: { event in diagnostics.mutate { $0.append(event.code) } }, logLevel: .debug, modules: [createICUModule()]))
        for (style, expected) in [("percent", "50%"), ("integer", "1"), ("::currency/USD", "$0.50"), ("::percent", "50%"), ("::precision-integer", "1"), ("::.00", "0.50"), ("::scale/100 precision-integer", "50"), ("::sign-always .00", "+0.50")] {
            XCTAssertEqual(try sdk.formatMessage("{n, number, \(style)}", values: ["n": .double(0.5)]), expected, style)
        }
        XCTAssertTrue(diagnostics.value.allSatisfy { $0 != "unsupported_formatter" })
        for token in ["made-up", "compact-long", "currency/INVALID", "scale/NaN"] {
            diagnostics.mutate { $0 = [] }
            XCTAssertThrowsError(try sdk.formatMessage("{n, number, ::\(token)}", values: ["n": .double(0.5)]))
            XCTAssertTrue(diagnostics.value.contains("unsupported_formatter"))
            XCTAssertTrue(diagnostics.value.contains("invalid_message"))
        }
        let custom = FormatPresets(number: ["percent": ["style": .string("currency"), "currency": .string("USD")]])
        let overridden = createMessagevisor(.init(locale: "en-US", defaultFormats: ["en-US": custom], logLevel: .fatal, modules: [createICUModule()]))
        XCTAssertEqual(try overridden.formatMessage("{n, number, percent}", values: ["n": .int(2)]), "$2.00")
    }

    func testSharedPluralSemanticsOffsetsFractionsAndEmptyBranches() throws {
        let sdk = createMessagevisor(.init(locale: "en", logLevel: .fatal, modules: [createICUModule()]))
        let all = "{n, plural, zero {zero} one {one} two {two} few {few} many {many} other {other}}"
        for (locale, value, expected) in [("ru", 1.5, "other"), ("fr", 1.5, "one"), ("cy", 2, "two"), ("ja", 1, "other"), ("pt-PT", 0, "other"), ("pt-BR", 0, "one")] {
            XCTAssertEqual(try sdk.formatMessage(all, values: ["n": .double(value)], options: .init(locale: locale)), expected)
            XCTAssertEqual(try sdk.formatPlural(value, locale: locale), expected)
        }
        XCTAssertEqual(try sdk.formatMessage("{n, plural, offset:1 =2 {exact} one {one} other {#}}", values: ["n": .int(2)]), "exact")
        XCTAssertEqual(try sdk.formatMessage("{n, plural, offset:1 one {one} other {#}}", values: ["n": .int(2)]), "one")
        XCTAssertEqual(try sdk.formatMessage("{n, plural, =1 {integer} =1.5 {} other {other}}", values: ["n": .double(1.5)]), "")
        XCTAssertEqual(try sdk.formatMessage("{n, selectordinal, one {one} two {two} few {few} other {other}}", values: ["n": .double(1.5)]), "other")
        for value in [Double.nan, .infinity, -.infinity, 1e100] {
            XCTAssertEqual(try sdk.formatMessage(all, values: ["n": .double(value)]), "other")
        }
    }

    func testMixedDateTimePresetsShareDirectFormatterConfiguration() throws {
        for locale in ["en-US", "en-GB", "fr", "ja"] {
            for options: FormatOptions in [["dateStyle": .string("short"), "timeStyle": .string("short")], ["year": .string("numeric"), "month": .string("long"), "day": .string("numeric"), "hour": .string("numeric"), "minute": .string("2-digit")], ["dateStyle": .string("short"), "timeStyle": .string("short"), "hour12": .bool(false), "hourCycle": .string("h12")]] {
                var resolved = options; resolved["timeZone"] = .string("UTC")
                let presets = FormatPresets(date: ["mixed": resolved], time: ["mixed": resolved])
                let sdk = createMessagevisor(.init(locale: locale, timeZone: "UTC", defaultFormats: [locale: presets], logLevel: .fatal, modules: [createICUModule()]))
                let direct = try sdk.formatDate(Date(timeIntervalSince1970: 0), preset: "mixed")
                XCTAssertEqual(try sdk.formatTime(Date(timeIntervalSince1970: 0), preset: "mixed"), direct)
                XCTAssertEqual(try sdk.formatMessage("{d, date, mixed}", values: ["d": .int(0)]), direct)
                XCTAssertEqual(try sdk.formatMessage("{d, time, mixed}", values: ["d": .int(0)]), direct)
                XCTAssertTrue(direct.contains("1970") || direct.contains("70"), direct)
                XCTAssertTrue(direct.contains(":"), direct)
                if options["hour12"]?.boolValue == false { XCTAssertFalse(direct.contains("AM"), direct) }
            }
        }
    }

    func testQuotedSyntaxAndPlaceholdersAreProcessedOnce() throws {
        let sdk = createMessagevisor(.init(locale: "en-US", logLevel: .fatal, modules: [createICUModule()]))
        XCTAssertEqual(try sdk.formatMessage("Literal '{name}', real {name}", values: ["name": .string("Ada")]), "Literal {name}, real Ada")
        XCTAssertEqual(try sdk.formatMessage("You don't need '{amount, number, missing}'"), "You don't need {amount, number, missing}")
        XCTAssertEqual(try sdk.formatMessage("'{quoted ''apostrophe''}'"), "{quoted 'apostrophe'}")
        XCTAssertEqual(try sdk.formatMessage("{n, plural, other {'#' # items}}", values: ["n": .int(2)]), "# 2 items")
        XCTAssertEqual(try sdk.formatMessage("A trailing apostrophe'"), "A trailing apostrophe'")
        XCTAssertThrowsError(try sdk.formatMessage("{n, plural,   ", values: ["n": .int(2)]))
        XCTAssertEqual(try sdk.formatMessage("{x, select, other {safe} unused {{missing}}}", values: ["x": .string("other")]), "safe")
        XCTAssertEqual(try sdk.formatMessage("{n, plural, other {{x, select, other {# items}}}}", values: ["n": .int(2), "x": .string("other")]), "2 items")
    }

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
