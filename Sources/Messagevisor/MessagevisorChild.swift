import Foundation

/// A request-scoped Messagevisor instance.
///
/// Children share their parent's datafiles, modules, resolver registry, and
/// formatter caches, while keeping locale, context, currency, time zone,
/// subscriptions, and snapshots isolated. Datafile and module ownership stays
/// on the root `Messagevisor` instance, so those mutation APIs are intentionally
/// absent here.
public final class MessagevisorChild: @unchecked Sendable {
    private let instance: Messagevisor

    init(instance: Messagevisor) { self.instance = instance }

    public func subscribe(_ callback: @escaping @Sendable () -> Void) -> MessagevisorUnsubscribe { instance.subscribe(callback) }
    public func on(_ name: MessagevisorEventName, _ callback: @escaping MessagevisorEventCallback) -> MessagevisorUnsubscribe { instance.on(name, callback) }
    public func setLogLevel(_ level: MessagevisorLogLevel) { instance.setLogLevel(level) }
    public func getSnapshot() -> MessagevisorSnapshot { instance.getSnapshot() }

    public func setFlagResolver(_ resolver: FlagResolver?) { instance.setFlagResolver(resolver) }
    public func setVariationResolver(_ resolver: VariationResolver?) { instance.setVariationResolver(resolver) }
    public func setCurrency(_ value: String) { instance.setCurrency(value) }
    public func getCurrency() -> String? { instance.getCurrency() }
    public func setTimeZone(_ value: String) { instance.setTimeZone(value) }
    public func getTimeZone() -> String? { instance.getTimeZone() }
    public func setContext(_ value: MessagevisorContext, replace: Bool = false) { instance.setContext(value, replace: replace) }
    public func getContext() -> MessagevisorContext { instance.getContext() }
    public func setLocale(_ value: String) throws { try instance.setLocale(value) }
    public func getLocale() -> String? { instance.getLocale() }
    public func getDirection(locale: String? = nil) throws -> String? { try instance.getDirection(locale: locale) }
    public func getDatafile(locale: String? = nil) throws -> DatafileContent { try instance.getDatafile(locale: locale) }
    public func getRevision(locale: String? = nil) throws -> String { try instance.getRevision(locale: locale) }
    public func getDefaultTranslations(locale: String? = nil) -> [String: String]? { instance.getDefaultTranslations(locale: locale) }
    public func getDefaultFormats(locale: String? = nil) -> FormatPresets? { instance.getDefaultFormats(locale: locale) }

    public func getRawTranslation(_ messageKey: String, options: TranslateOptions = .init()) throws -> String { try instance.getRawTranslation(messageKey, options: options) }
    public func translate(_ messageKey: String, values: MessagevisorValues = [:], options: TranslateOptions = .init()) throws -> String { try instance.translate(messageKey, values: values, options: options) }
    public func t(_ messageKey: String, values: MessagevisorValues = [:], options: TranslateOptions = .init()) throws -> String { try instance.t(messageKey, values: values, options: options) }
    public func formatMessage(_ message: String, values: MessagevisorValues = [:], options: EvaluationOptions = .init()) throws -> String { try instance.formatMessage(message, values: values, options: options) }

    public func formatNumber(_ value: Double, preset: String? = nil, options: EvaluationOptions = .init()) throws -> String { try instance.formatNumber(value, preset: preset, options: options) }
    public func formatNumber(_ value: Double, formatOptions: FormatOptions, options: EvaluationOptions = .init()) throws -> String { try instance.formatNumber(value, formatOptions: formatOptions, options: options) }
    public func formatNumberToParts(_ value: Double, preset: String? = nil, options: EvaluationOptions = .init()) throws -> [MessagevisorFormatPart] { try instance.formatNumberToParts(value, preset: preset, options: options) }
    public func formatDate(_ value: Date, preset: String? = nil, options: EvaluationOptions = .init()) throws -> String { try instance.formatDate(value, preset: preset, options: options) }
    public func formatTime(_ value: Date, preset: String? = nil, options: EvaluationOptions = .init()) throws -> String { try instance.formatTime(value, preset: preset, options: options) }
    public func formatDateToParts(_ value: Date, preset: String? = nil, options: EvaluationOptions = .init()) throws -> [MessagevisorFormatPart] { try instance.formatDateToParts(value, preset: preset, options: options) }
    public func formatTimeToParts(_ value: Date, preset: String? = nil, options: EvaluationOptions = .init()) throws -> [MessagevisorFormatPart] { try instance.formatTimeToParts(value, preset: preset, options: options) }
    public func formatDateTimeRange(_ start: Date, _ end: Date, preset: String? = nil, options: EvaluationOptions = .init()) throws -> String { try instance.formatDateTimeRange(start, end, preset: preset, options: options) }
    public func formatRelativeTime(_ value: Double, unit: Calendar.Component, preset: String? = nil, options: EvaluationOptions = .init()) throws -> String { try instance.formatRelativeTime(value, unit: unit, preset: preset, options: options) }
    public func formatRelativeTimeToParts(_ value: Double, unit: Calendar.Component, preset: String? = nil, options: EvaluationOptions = .init()) throws -> [MessagevisorFormatPart] { try instance.formatRelativeTimeToParts(value, unit: unit, preset: preset, options: options) }
    public func formatPlural(_ value: Double, locale: String? = nil, ordinal: Bool = false) throws -> String { try instance.formatPlural(value, locale: locale, ordinal: ordinal) }
    public func formatPlural(_ value: Double, formatOptions: FormatOptions, locale: String? = nil) throws -> String { try instance.formatPlural(value, formatOptions: formatOptions, locale: locale) }
    public func formatList(_ values: [String], locale: String? = nil) throws -> String { try instance.formatList(values, locale: locale) }
    public func formatList(_ values: [String], formatOptions: FormatOptions, locale: String? = nil) throws -> String { try instance.formatList(values, formatOptions: formatOptions, locale: locale) }
    public func formatListToParts(_ values: [String], locale: String? = nil) throws -> [MessagevisorFormatPart] { try instance.formatListToParts(values, locale: locale) }
    public func formatListToParts(_ values: [String], formatOptions: FormatOptions, locale: String? = nil) throws -> [MessagevisorFormatPart] { try instance.formatListToParts(values, formatOptions: formatOptions, locale: locale) }
    public func formatDisplayName(_ value: String, type: String, locale: String? = nil) throws -> String? { try instance.formatDisplayName(value, type: type, locale: locale) }
    public func formatDisplayName(_ value: String, formatOptions: FormatOptions, locale: String? = nil) throws -> String? { try instance.formatDisplayName(value, formatOptions: formatOptions, locale: locale) }

    public func close() async throws { try await instance.close() }
}
