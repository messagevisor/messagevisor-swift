import XCTest
@testable import Messagevisor

final class FormattingTests: XCTestCase {
    func testDefaultDatafileAndPerCallFormatsMerge() throws {
        let defaults = FormatPresets(number: ["amount": ["minimumFractionDigits": .int(1), "maximumFractionDigits": .int(1)]])
        let datafileFormats = FormatPresets(number: ["amount": ["minimumFractionDigits": .int(2), "maximumFractionDigits": .int(2)]])
        let datafile = DatafileContent(messagevisorVersion: "test", target: "swift", locale: "en-US", formats: datafileFormats)
        let sdk = createMessagevisor(.init(datafile: datafile, defaultFormats: ["en-US": defaults], logLevel: .fatal))

        XCTAssertEqual(try sdk.formatNumber(12, preset: "amount"), "12.00")
        let callFormats = FormatPresets(number: ["amount": ["minimumFractionDigits": .int(3), "maximumFractionDigits": .int(3)]])
        XCTAssertEqual(try sdk.formatNumber(12, preset: "amount", options: .init(formats: callFormats)), "12.000")
    }

    func testNamedFormatErrorsAndSimplifiedPartsAreObservable() throws {
        let diagnostics = ConcurrencyBox<[MessagevisorDiagnostic]>([])
        let formats = FormatPresets(date: ["broken": ["timeZone": .string("Not/AZone")]])
        let sdk = createMessagevisor(.init(locale: "en-US", defaultFormats: ["en-US": formats], onDiagnostic: { diagnostic in diagnostics.mutate { $0.append(diagnostic) } }, logLevel: .debug))
        XCTAssertThrowsError(try sdk.formatNumber(1, preset: "missing"))
        XCTAssertEqual(diagnostics.value.last?.code, "missing_format")

        let parts = try sdk.formatNumberToParts(1234)
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].type, "literal")
        XCTAssertFalse(parts[0].value.isEmpty)
        XCTAssertTrue(diagnostics.value.contains { $0.code == "unsupported_formatter" })
    }

    func testNativeFormatterFamiliesAndPerCallLocale() throws {
        let sdk = createMessagevisor(.init(locale: "en-US", currency: "USD", timeZone: "UTC", logLevel: .fatal))
        XCTAssertTrue(try sdk.formatNumber(1234.5).contains("1,234"))
        XCTAssertFalse(try sdk.formatDate(Date(timeIntervalSince1970: 0), options: .init(locale: "nl-NL")).isEmpty)
        XCTAssertFalse(try sdk.formatTime(Date(timeIntervalSince1970: 0)).isEmpty)
        XCTAssertFalse(try sdk.formatDateTimeRange(Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 3600)).isEmpty)
        XCTAssertFalse(try sdk.formatRelativeTime(-1, unit: Calendar.Component.day).isEmpty)
        XCTAssertEqual(try sdk.formatPlural(1), "one")
        XCTAssertEqual(try sdk.formatPlural(2, formatOptions: ["type": .string("ordinal")]), "two")
        XCTAssertTrue(try sdk.formatList(["A", "B"]).contains("A"))
        XCTAssertTrue(try sdk.formatList(["A", "B"], formatOptions: ["type": .string("conjunction")]).contains("B"))
        XCTAssertNotNil(try sdk.formatDisplayName("NL", type: "region"))
        XCTAssertNotNil(try sdk.formatDisplayName("Latn", formatOptions: ["type": .string("script")]))
        XCTAssertEqual(sdk.getLocale(), "en-US")
    }

    func testPortableDateSupportsSubMillisecondPrecision() {
        XCTAssertNotNil(MessagevisorValue.string("2026-11-26T15:05:00.123456Z").dateValue)
        XCTAssertNotNil(MessagevisorValue.string("2026-11-26T15:05:00+01:00").dateValue)
        XCTAssertNil(MessagevisorValue.string("2026-11-26").dateValue)
        XCTAssertNil(MessagevisorValue.string("2026-11-26T15:05:00").dateValue)
    }

    func testInvalidFormatOptionsEmitPortableDiagnostic() throws {
        let diagnostics = ConcurrencyBox<[MessagevisorDiagnostic]>([])
        let sdk = createMessagevisor(.init(locale: "en-US", onDiagnostic: { diagnostic in diagnostics.mutate { $0.append(diagnostic) } }, logLevel: .debug))

        XCTAssertThrowsError(try sdk.formatNumber(1, formatOptions: ["style": .string("currency"), "currency": .string("INVALID")]))
        XCTAssertThrowsError(try sdk.formatDate(Date(), preset: "broken"))
        XCTAssertTrue(diagnostics.value.contains { $0.code == "invalid_format" && $0.details["type"] == .string("number") })
    }

    func testCompactAndNarrowFormattingUseFoundationLocaleData() throws {
        let formats = FormatPresets(date: ["narrow": ["month": .string("narrow"), "timeZone": .string("UTC")]])
        let sdk = createMessagevisor(.init(locale: "fr-FR", defaultFormats: ["fr-FR": formats], logLevel: .fatal))
        let compact = try sdk.formatNumber(1_200, formatOptions: ["notation": .string("compact")])
        XCTAssertFalse(compact.contains("K"), "Compact output must not use a hard-coded English suffix")
        XCTAssertFalse(try sdk.formatDate(Date(timeIntervalSince1970: 0), preset: "narrow").isEmpty)
    }

    func testExplicitCurrencyNumberingSystemHourCycleAndSignsAreHonoured() throws {
        let timeFormats = FormatPresets(time: [
            "h11": ["hour": .string("numeric"), "hourCycle": .string("h11"), "timeZone": .string("UTC")],
            "h24": ["hour": .string("numeric"), "hourCycle": .string("h24"), "timeZone": .string("UTC")],
        ])
        let sdk = createMessagevisor(.init(locale: "en-US", currency: "USD", timeZone: "UTC", defaultFormats: ["en-US": timeFormats], logLevel: .fatal))

        let euros = try sdk.formatNumber(12, formatOptions: [
            "style": .string("currency"),
            "currency": .string("EUR"),
            "currencyDisplay": .string("code"),
        ])
        XCTAssertTrue(euros.contains("EUR"))
        XCTAssertFalse(euros.contains("USD"))

        let arabicDigits = try sdk.formatNumber(123, formatOptions: ["numberingSystem": .string("arab")])
        XCTAssertTrue(arabicDigits.contains("١٢٣"))

        let positive = try sdk.formatNumber(2, formatOptions: ["signDisplay": .string("always")])
        let hiddenNegative = try sdk.formatNumber(-2, formatOptions: ["signDisplay": .string("never")])
        XCTAssertTrue(positive.contains("+"))
        XCTAssertFalse(hiddenNegative.contains("-"))

        let midnight = Date(timeIntervalSince1970: 0)
        let h11 = try sdk.formatTime(midnight, preset: "h11")
        let h24 = try sdk.formatTime(midnight, preset: "h24")
        XCTAssertNotEqual(h11, h24)
    }

    func testPortableHalfRoundingModesHandleNegativeTies() throws {
        let sdk = createMessagevisor(.init(locale: "en-US", logLevel: .fatal))
        let base: FormatOptions = ["maximumFractionDigits": .int(0)]

        XCTAssertEqual(
            try sdk.formatNumber(-2.5, formatOptions: base.merging(["roundingMode": .string("halfCeil")]) { _, new in new }),
            "-2"
        )
        XCTAssertEqual(
            try sdk.formatNumber(-2.5, formatOptions: base.merging(["roundingMode": .string("halfFloor")]) { _, new in new }),
            "-3"
        )
        XCTAssertEqual(
            try sdk.formatNumber(2.5, formatOptions: base.merging(["roundingMode": .string("halfCeil")]) { _, new in new }),
            "3"
        )
        XCTAssertEqual(
            try sdk.formatNumber(2.5, formatOptions: base.merging(["roundingMode": .string("halfFloor")]) { _, new in new }),
            "2"
        )
    }
}
