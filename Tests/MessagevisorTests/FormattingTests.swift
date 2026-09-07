import XCTest
@testable import Messagevisor

final class FormattingTests: XCTestCase {
    func testDayPeriodWidthsUseNativeFlexibleDayPeriods() throws {
        for locale in ["en-US", "fr-FR", "nl-NL", "ar-SA"] {
            let sdk = createMessagevisor(.init(locale: locale, logLevel: .fatal))
            for (width, template) in [("short", "hB"), ("long", "hBBBB"), ("narrow", "hBBBBB")] {
                for hour in [8, 12, 19] {
                    let date = Date(timeIntervalSince1970: Double(hour * 3600))
                    let native = DateFormatter(); native.locale = Locale(identifier: locale); native.timeZone = TimeZone(identifier: "UTC")
                    native.setLocalizedDateFormatFromTemplate(template)
                    let options = EvaluationOptions(formats: .init(time: ["period": ["hour": .string("numeric"), "hour12": .bool(true), "dayPeriod": .string(width), "timeZone": .string("UTC")]]))
                    XCTAssertEqual(try sdk.formatTime(date, preset: "period", options: options), native.string(from: date), "\(locale): \(width), \(hour)")
                }
            }
        }
    }

    func testExplicitTwelveHourCycleDoesNotImplicitlyRequestFlexibleDayPeriods() throws {
        let sdk = createMessagevisor(.init(locale: "es-ES", logLevel: .fatal))
        let date = Date(timeIntervalSince1970: 8.5 * 3600)
        let native = DateFormatter(); native.locale = Locale(identifier: "es-ES"); native.timeZone = TimeZone(identifier: "UTC")
        native.setLocalizedDateFormatFromTemplate("hma")
        for cycle: FormatOptions in [["hour12": .bool(true)], ["hourCycle": .string("h11")], ["hourCycle": .string("h12")]] {
            var preset = cycle; preset["hour"] = .string("numeric"); preset["minute"] = .string("numeric"); preset["timeZone"] = .string("UTC")
            XCTAssertEqual(try sdk.formatTime(date, preset: "clock", options: .init(formats: .init(time: ["clock": preset]))), native.string(from: date))
        }
    }

    func testPluralOperandsPrecisionLocaleFallbackAndNonFiniteValues() throws {
        let sdk = createMessagevisor(.init(locale: "en", logLevel: .fatal))
        XCTAssertEqual(try sdk.formatPlural(1, formatOptions: ["minimumFractionDigits": .int(2)]), "other")
        XCTAssertEqual(try sdk.formatPlural(1, formatOptions: ["minimumSignificantDigits": .int(3)]), "other")
        XCTAssertEqual(try sdk.formatPlural(1.4, formatOptions: ["maximumFractionDigits": .int(0)]), "one")
        XCTAssertEqual(try sdk.formatPlural(-1, locale: "en"), "one")
        XCTAssertEqual(try sdk.formatPlural(0, locale: "pt-PT-u-nu-latn"), "other")
        XCTAssertEqual(try sdk.formatPlural(0, locale: "pt_BR"), "one")
        XCTAssertEqual(try sdk.formatPlural(0, locale: "pt-AO"), "other")
        XCTAssertEqual(try sdk.formatPlural(0, locale: "pt-Latn-PT"), "other")
        XCTAssertEqual(try sdk.formatPlural(2, locale: "cy-GB"), "two")
        XCTAssertEqual(try sdk.formatPlural(1, locale: "ja"), "other")
        for locale in ["ru", "ar", "en", "fr", "cy", "ja"] {
            for value in [Double.nan, .infinity, -.infinity] {
                XCTAssertEqual(try sdk.formatPlural(value, locale: locale), "other")
                XCTAssertEqual(try sdk.formatPlural(value, locale: locale, ordinal: true), "other")
            }
        }
        for options: FormatOptions in [["minimumFractionDigits": .int(-1)], ["maximumFractionDigits": .double(.nan)], ["minimumFractionDigits": .int(4), "maximumFractionDigits": .int(2)], ["maximumSignificantDigits": .int(0)]] {
            XCTAssertThrowsError(try sdk.formatPlural(1, formatOptions: options))
        }
    }

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
        XCTAssertEqual(try sdk.formatNumber(1, preset: "missing"), try sdk.formatNumber(1))
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
        XCTAssertNoThrow(try sdk.formatDate(Date(), preset: "missing"))
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
