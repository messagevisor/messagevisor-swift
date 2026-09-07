import Foundation

private final class SharedStorage: @unchecked Sendable {
    let lock = NSRecursiveLock()
    var datafiles: [String: DatafileContent] = [:]
    var defaultTranslations: [String: [String: String]] = [:]
    var defaultFormats: [String: FormatPresets] = [:]
    let formatters = NativeFormatters()
}

private struct ModuleDiagnosticSubscription: Sendable {
    let id: UUID
    let moduleID: UUID
    let handler: MessagevisorDiagnosticHandler
    let logLevel: MessagevisorLogLevel
}

private struct ModuleFlagResolver: Sendable { let moduleID: UUID; let resolver: FlagResolver }
private struct ModuleVariationResolver: Sendable { let moduleID: UUID; let resolver: VariationResolver }
private struct ParentSubscription: Sendable { let id: UUID; let unsubscribe: MessagevisorUnsubscribe }
private final class CallbackState: @unchecked Sendable {
    var active = true
}
private final class WeakInstance {
    weak var value: Messagevisor?
    init(_ value: Messagevisor) { self.value = value }
}

public final class Messagevisor: @unchecked Sendable {
    private let storage: SharedStorage
    private weak var parent: Messagevisor?
    private var context: MessagevisorContext
    private var locale: String?
    private var currency: String?
    private var timeZone: String?
    private var ownFlagResolver: FlagResolver?
    private var ownVariationResolver: VariationResolver?
    private var hasOwnFlagResolver = false
    private var hasOwnVariationResolver = false
    private var diagnosticHandler: MessagevisorDiagnosticHandler?
    private var logLevel: MessagevisorLogLevel
    private var modules: [MessagevisorModule] = []
    private var moduleSubscriptions: [ModuleDiagnosticSubscription] = []
    private var moduleApis: [UUID: MessagevisorModuleApi] = [:]
    private var moduleStates: [UUID: CallbackState] = [:]
    private let childID = UUID()
    private var children: [UUID: WeakInstance] = [:]
    private var moduleFlagResolvers: [ModuleFlagResolver] = []
    private var moduleVariationResolvers: [ModuleVariationResolver] = []
    private var pendingModuleCleanupTasks: [Task<Void, Never>] = []
    private var closeTask: Task<Void, Never>?
    private var closeErrors: [Error] = []
    private var version = 0
    private var closed = false
    private let emitter = MessagevisorEmitter()
    private var parentSubscriptions: [ParentSubscription] = []
    private var observedParentDatafileLocales: [String] = []
    private var observedParentDatafileRevisions: [String: String] = [:]
    private var observedParentDirection: String?

    public init(options: MessagevisorOptions = .init()) {
        storage = SharedStorage(); context = options.context
        locale = options.datafile == nil && options.datafileJSON == nil ? options.locale : nil
        currency = options.currency; timeZone = options.timeZone
        ownFlagResolver = options.resolveFlag; ownVariationResolver = options.resolveVariation
        hasOwnFlagResolver = options.resolveFlag != nil; hasOwnVariationResolver = options.resolveVariation != nil
        diagnosticHandler = options.onDiagnostic; logLevel = options.logLevel
        storage.defaultTranslations = options.defaultTranslations; storage.defaultFormats = options.defaultFormats
        if let datafile = options.datafile { setDatafile(datafile) }
        else if let json = options.datafileJSON { setDatafile(json) }
        for module in options.modules { _ = addModule(module) }
        report(.init(level: .info, code: "sdk_initialized", message: "SDK initialized"))
    }

    private init(parent: Messagevisor, context: MessagevisorContext, options: SpawnOptions) {
        self.parent = parent; storage = parent.storage
        self.context = parent.context.merging(context) { _, new in new }
        locale = options.locale ?? parent.locale; currency = options.currency ?? parent.currency; timeZone = options.timeZone ?? parent.timeZone
        diagnosticHandler = parent.diagnosticHandler; logLevel = parent.logLevel
        captureObservedParentDatafileState()
        _ = trackParentSubscription(parent.on(.datafileSet) { [weak self] event in
            self?.forwardParentDatafileEvent(event)
        })
    }

    public func spawn(context: MessagevisorContext = [:], options: SpawnOptions = .init()) -> MessagevisorChild {
        storage.lock.lock(); defer { storage.lock.unlock() }
        let child = Messagevisor(parent: self, context: context, options: options)
        children = children.filter { $0.value.value != nil }
        children[child.childID] = WeakInstance(child)
        return MessagevisorChild(instance: child)
    }

    public func subscribe(_ callback: @escaping @Sendable () -> Void) -> MessagevisorUnsubscribe {
        on(.change) { _ in callback() }
    }

    public func on(_ name: MessagevisorEventName, _ callback: @escaping MessagevisorEventCallback) -> MessagevisorUnsubscribe {
        storage.lock.lock(); defer { storage.lock.unlock() }
        guard !closed else { return {} }
        return localOn(name, callback)
    }

    private func captureObservedParentDatafileState() {
        let snapshot = getSnapshot()
        observedParentDatafileLocales = snapshot.datafileLocales
        observedParentDatafileRevisions = snapshot.datafileRevisionsByLocale
        observedParentDirection = snapshot.direction
    }

    private func forwardParentDatafileEvent(_ event: MessagevisorEvent) {
        storage.lock.withLock {
            guard !closed,
                  case .datafileSet(let datafile, let datafileLocale, _, _, let replaced) = event.details
            else { return }
            let current = getSnapshot()
            let previous = MessagevisorSnapshot(
                version: version,
                locale: current.locale,
                direction: observedParentDirection,
                context: current.context,
                currency: current.currency,
                timeZone: current.timeZone,
                datafileLocales: observedParentDatafileLocales,
                datafileRevisionsByLocale: observedParentDatafileRevisions
            )
            emit(.datafileSet, previous, .datafileSet(datafile: datafile, locale: datafileLocale, activeLocale: locale, previousLocale: locale, replaced: replaced))
            captureObservedParentDatafileState()
        }
    }

    private func localOn(_ name: MessagevisorEventName, _ callback: @escaping MessagevisorEventCallback) -> MessagevisorUnsubscribe {
        let unsubscribe = emitter.on(name, callback)
        return { [weak self] in self?.storage.lock.withLock { unsubscribe() } }
    }

    private func trackParentSubscription(_ parentUnsubscribe: @escaping MessagevisorUnsubscribe) -> MessagevisorUnsubscribe {
        let id = UUID()
        let state = CallbackState()
        let tracked: MessagevisorUnsubscribe = { [weak self] in
            self?.storage.lock.withLock {
                guard state.active else { return }
                state.active = false
                parentUnsubscribe()
                self?.parentSubscriptions.removeAll { $0.id == id }
            }
        }
        parentSubscriptions.append(.init(id: id, unsubscribe: tracked))
        return tracked
    }

    public func setLogLevel(_ level: MessagevisorLogLevel) { storage.lock.withLock { logLevel = level } }

    public func getSnapshot() -> MessagevisorSnapshot {
        storage.lock.withLock {
            .init(version: version, locale: locale, direction: locale.flatMap { storage.datafiles[$0]?.direction }, context: context, currency: currency, timeZone: timeZone, datafileLocales: storage.datafiles.keys.sorted(), datafileRevisionsByLocale: storage.datafiles.mapValues(\.revision))
        }
    }

    @discardableResult
    public func addModule(_ module: MessagevisorModule) -> MessagevisorModuleRemoval {
        storage.lock.lock(); defer { storage.lock.unlock() }
        guard !closed else { return {} }
        guard parent == nil else { return { throw MessagevisorError("Modules are managed by the parent Messagevisor instance.") } }
        if let name = module.name, modules.contains(where: { $0.name == name }) {
            report(.init(level: .error, code: "duplicate_module", message: "Duplicate module name", moduleName: name))
            return {}
        }
        moduleStates[module.id] = CallbackState()
        do { try module.setup?(moduleApi(for: module)) }
        catch {
            clearModuleResources(module)
            if module.close != nil {
                pendingModuleCleanupTasks.append(Task { [weak self] in try? await self?.closeModule(module) })
            }
            report(.init(level: .error, code: "module_setup_error", message: "Module setup failed", moduleName: module.name, originalError: error.localizedDescription))
            return {}
        }
        modules.append(module)
        let state = CallbackState()
        return { [weak self] in
            guard let self else { return }
            let removal = self.storage.lock.withLock { () -> (exists: Bool, cleanup: [Task<Void, Never>]) in
                guard state.active else { return (false, []) }
                state.active = false
                let exists = self.modules.contains { $0.id == module.id }
                self.modules.removeAll { $0.id == module.id }; self.clearModuleResources(module)
                let cleanup = self.pendingModuleCleanupTasks
                self.pendingModuleCleanupTasks.removeAll()
                return (exists, cleanup)
            }
            for task in removal.cleanup { await task.value }
            if removal.exists { try await self.closeModule(module) }
        }
    }

    public func removeModule(_ name: String) async throws {
        let removed: [MessagevisorModule] = try storage.lock.withLock {
            guard parent == nil else { throw MessagevisorError("Modules are managed by the parent Messagevisor instance.") }
            let removed = modules.filter { $0.name == name }; modules.removeAll { $0.name == name }
            removed.forEach(clearModuleResources); return removed
        }
        var errors: [Error] = []
        for module in removed { do { try await closeModule(module) } catch { errors.append(error) } }
        if !errors.isEmpty { throw MessagevisorCloseError(errors: errors) }
    }

    public func setFlagResolver(_ resolver: FlagResolver?) { storage.lock.withLock { ownFlagResolver = resolver; hasOwnFlagResolver = true } }
    public func setVariationResolver(_ resolver: VariationResolver?) { storage.lock.withLock { ownVariationResolver = resolver; hasOwnVariationResolver = true } }

    public func setCurrency(_ value: String) {
        storage.lock.withLock { let old = getSnapshot(); let previous = currency; currency = value; emit(.currencySet, old, .currencySet(currency: value, previousCurrency: previous)) }
    }
    public func getCurrency() -> String? { storage.lock.withLock { currency } }
    public func setTimeZone(_ value: String) {
        storage.lock.withLock { let old = getSnapshot(); let previous = timeZone; timeZone = value; emit(.timeZoneSet, old, .timeZoneSet(timeZone: value, previousTimeZone: previous)) }
    }
    public func getTimeZone() -> String? { storage.lock.withLock { timeZone } }

    public func setContext(_ value: MessagevisorContext, replace: Bool = false) {
        storage.lock.withLock {
            let old = getSnapshot(), previous = context
            context = replace ? value : context.merging(value) { _, new in new }
            emit(.contextSet, old, .contextSet(context: context, previousContext: previous, replaced: replace))
        }
    }
    public func getContext() -> MessagevisorContext { storage.lock.withLock { context } }

    public func setDatafile(_ json: String, replace: Bool = false) {
        guard parent == nil else { return }
        do { setDatafile(try DatafileContent.fromJSON(json), replace: replace) }
        catch { report(.init(level: .error, code: "invalid_datafile", message: "could not parse datafile", originalError: error.localizedDescription)) }
    }

    public func setDatafile(_ incoming: DatafileContent, replace: Bool = false) {
        guard parent == nil else { return }
        storage.lock.withLock {
            guard incoming.schemaVersion == "1", !incoming.locale.isEmpty,
                  incoming.direction == nil || ["ltr", "rtl"].contains(incoming.direction!) else {
                report(.init(level: .error, code: "invalid_datafile", message: "could not parse datafile", originalError: "Invalid datafile identity or direction.")); return
            }
            let old = getSnapshot(), previousLocale = locale
            let stored = !replace && storage.datafiles[incoming.locale] != nil ? mergeDatafile(storage.datafiles[incoming.locale]!, incoming) : incoming
            storage.datafiles[stored.locale] = stored
            if locale == nil { locale = stored.locale }
            emit(.datafileSet, old, .datafileSet(datafile: stored, locale: stored.locale, activeLocale: locale, previousLocale: previousLocale, replaced: replace))
        }
    }

    public func setLocale(_ value: String) throws {
        try storage.lock.withLock {
            guard storage.datafiles[value] != nil else {
                report(.init(level: .error, code: "missing_datafile", message: "Datafile not found for locale", details: ["locale": .string(value)]))
                throw MessagevisorError("Datafile not found for locale: \(value)")
            }
            let old = getSnapshot(), previous = locale; locale = value
            emit(.localeSet, old, .localeSet(locale: value, previousLocale: previous))
        }
    }
    public func getLocale() -> String? { storage.lock.withLock { locale } }
    public func getDirection(locale requested: String? = nil) throws -> String? {
        try storage.lock.withLock {
            guard let selected = requested ?? locale else { return nil }
            return try getDatafile(locale: selected).direction
        }
    }
    public func getDatafile(locale requested: String? = nil) throws -> DatafileContent {
        try storage.lock.withLock {
            guard let selected = requested ?? locale else {
                report(.init(level: .error, code: "missing_locale", message: "Datafile not found: no locale is set", details: ["locale": .null])); throw MessagevisorError("Datafile not found: no locale is set")
            }
            guard let datafile = storage.datafiles[selected] else {
                report(.init(level: .error, code: "missing_datafile", message: "Datafile not found for locale", details: ["locale": .string(selected)])); throw MessagevisorError("Datafile not found for locale: \(selected)")
            }
            return datafile
        }
    }
    public func getRevision(locale: String? = nil) throws -> String { try getDatafile(locale: locale).revision }

    public func getDefaultTranslations(locale requested: String? = nil) -> [String: String]? {
        storage.lock.withLock {
            guard let selected = requested ?? locale else { return nil }
            return storage.defaultTranslations[selected]
        }
    }

    public func getDefaultFormats(locale requested: String? = nil) -> FormatPresets? {
        storage.lock.withLock {
            guard let selected = requested ?? locale else { return nil }
            return storage.defaultFormats[selected]
        }
    }

    public func getRawTranslation(_ messageKey: String, options: TranslateOptions = .init()) throws -> String {
        try storage.lock.withLock { try resolveMessage(messageKey, options: options).translation }
    }

    public func translate(_ messageKey: String, values: MessagevisorValues = [:], options: TranslateOptions = .init()) throws -> String {
        try storage.lock.withLock {
            let resolved = try resolveMessage(messageKey, options: options)
            let datafile = storage.datafiles[resolved.locale]
            let meta = datafile?.messages[messageKey]?.meta
            let formats = evaluationFormats(options.evaluation, locale: resolved.locale)
            let payload = MessagevisorFormatPayload(translation: resolved.translation, values: values, locale: resolved.locale, source: .translation, messageKey: messageKey, meta: meta, formats: formats, moduleOptions: options.moduleOptions, currency: options.currency ?? currency, timeZone: options.timeZone ?? timeZone ?? storage.formatters.defaultTimeZone)
            return try runModules(payload)
        }
    }

    public func t(_ messageKey: String, values: MessagevisorValues = [:], options: TranslateOptions = .init()) throws -> String {
        try translate(messageKey, values: values, options: options)
    }

    public func formatMessage(_ message: String, values: MessagevisorValues = [:], options: EvaluationOptions = .init()) throws -> String {
        try storage.lock.withLock {
            let selected = try currentLocale(options.locale)
            let payload = MessagevisorFormatPayload(translation: message, values: values, locale: selected, source: .formatMessage, messageKey: nil, meta: nil, formats: evaluationFormats(options, locale: selected), moduleOptions: options.moduleOptions, currency: options.currency ?? currency, timeZone: options.timeZone ?? timeZone ?? storage.formatters.defaultTimeZone)
            return try runModules(payload)
        }
    }

    public func formatNumber(_ value: Double, preset: String? = nil, options: EvaluationOptions = .init()) throws -> String {
        try storage.lock.withLock {
            let selected = try currentLocale(options.locale), formats = evaluationFormats(options, locale: selected)
            let formatOptions = try named(preset, type: "number", values: formats.number, locale: selected)
            return try formatNumberValue(value, formatOptions: formatOptions, locale: selected, currency: options.currency ?? currency)
        }
    }
    public func formatNumber(_ value: Double, formatOptions: FormatOptions, options: EvaluationOptions = .init()) throws -> String {
        try storage.lock.withLock { let selected = try currentLocale(options.locale); return try formatNumberValue(value, formatOptions: formatOptions, locale: selected, currency: options.currency ?? currency) }
    }
    public func formatNumberToParts(_ value: Double, preset: String? = nil, options: EvaluationOptions = .init()) throws -> [MessagevisorFormatPart] {
        reportSimplifiedParts("formatNumberToParts", locale: options.locale)
        return [.init(type: "literal", value: try formatNumber(value, preset: preset, options: options))]
    }

    public func formatDate(_ value: Date, preset: String? = nil, options: EvaluationOptions = .init()) throws -> String { try formatDateValue(value, type: "date", preset: preset, options: options) }
    public func formatTime(_ value: Date, preset: String? = nil, options: EvaluationOptions = .init()) throws -> String { try formatDateValue(value, type: "time", preset: preset, options: options) }
    public func formatDateToParts(_ value: Date, preset: String? = nil, options: EvaluationOptions = .init()) throws -> [MessagevisorFormatPart] {
        reportSimplifiedParts("formatDateToParts", locale: options.locale)
        return [.init(type: "literal", value: try formatDate(value, preset: preset, options: options))]
    }
    public func formatTimeToParts(_ value: Date, preset: String? = nil, options: EvaluationOptions = .init()) throws -> [MessagevisorFormatPart] {
        reportSimplifiedParts("formatTimeToParts", locale: options.locale)
        return [.init(type: "literal", value: try formatTime(value, preset: preset, options: options))]
    }

    public func formatDateTimeRange(_ start: Date, _ end: Date, preset: String? = nil, options: EvaluationOptions = .init()) throws -> String {
        try storage.lock.withLock {
            let selected = try currentLocale(options.locale), formats = evaluationFormats(options, locale: selected)
            let formatOptions = try named(preset, type: "dateTimeRange", values: formats.dateTimeRange, locale: selected)
            let zone = options.timeZone ?? formatOptions["timeZone"]?.stringValue ?? timeZone ?? storage.formatters.defaultTimeZone
            try validateTimeZone(zone, type: "dateTimeRange", locale: selected, options: formatOptions)
            try validateDate(start, type: "dateTimeRange", locale: selected, options: formatOptions)
            try validateDate(end, type: "dateTimeRange", locale: selected, options: formatOptions)
            let formatter = DateIntervalFormatter(); formatter.locale = Locale(identifier: selected); formatter.timeZone = TimeZone(identifier: zone)
            if let style = formatOptions["dateStyle"]?.stringValue { formatter.dateStyle = dateStyle(style) }
            if let style = formatOptions["timeStyle"]?.stringValue { formatter.timeStyle = dateStyle(style) }
            return formatter.string(from: start, to: end)
        }
    }

    public func formatRelativeTime(_ value: Double, unit: Calendar.Component, preset: String? = nil, options: EvaluationOptions = .init()) throws -> String {
        try storage.lock.withLock {
            let selected = try currentLocale(options.locale), formats = evaluationFormats(options, locale: selected)
            let formatOptions = try named(preset, type: "relative", values: formats.relative, locale: selected)
            guard relativeInterval(value, unit).isFinite else { try invalidFormat(type: "relative", locale: selected, options: formatOptions, reason: "Relative time must be finite") }
            let formatter = RelativeDateTimeFormatter(); formatter.locale = Locale(identifier: selected)
            formatter.unitsStyle = formatOptions["style"]?.stringValue == "short" ? .short : formatOptions["style"]?.stringValue == "narrow" ? .abbreviated : .full
            return formatter.localizedString(fromTimeInterval: relativeInterval(value, unit))
        }
    }
    public func formatRelativeTimeToParts(_ value: Double, unit: Calendar.Component, preset: String? = nil, options: EvaluationOptions = .init()) throws -> [MessagevisorFormatPart] {
        reportSimplifiedParts("formatRelativeTimeToParts", locale: options.locale)
        return [.init(type: "literal", value: try formatRelativeTime(value, unit: unit, preset: preset, options: options))]
    }
    public func formatPlural(_ value: Double, locale: String? = nil, ordinal: Bool = false) throws -> String { try storage.lock.withLock { try messagevisorPluralCategory(value, locale: currentLocale(locale), ordinal: ordinal) } }
    public func formatPlural(_ value: Double, formatOptions: FormatOptions, locale: String? = nil) throws -> String {
        try storage.lock.withLock {
            let selected = try currentLocale(locale ?? formatOptions["locale"]?.stringValue)
            for key in ["roundingPriority", "roundingIncrement", "roundingMode", "trailingZeroDisplay"] where formatOptions[key] != nil {
                report(.init(level: .warn, code: "unsupported_formatter", message: "Plural rounding option is not supported", details: ["formatter": .string("formatPlural"), "option": .string(key), "locale": .string(selected)]))
            }
            do { return try messagevisorPluralCategory(value, locale: selected, ordinal: formatOptions["type"]?.stringValue == "ordinal", options: formatOptions) }
            catch { try invalidFormat(type: "plural", locale: selected, options: formatOptions, reason: error.localizedDescription) }
        }
    }
    public func formatList(_ values: [String], locale: String? = nil) throws -> String {
        try storage.lock.withLock {
            let formatter = ListFormatter(); formatter.locale = Locale(identifier: try currentLocale(locale))
            return formatter.string(from: values) ?? values.joined(separator: ", ")
        }
    }
    public func formatList(_ values: [String], formatOptions: FormatOptions, locale: String? = nil) throws -> String {
        let selected = locale ?? formatOptions["locale"]?.stringValue
        if formatOptions["type"] != nil || formatOptions["style"] != nil {
            storage.lock.withLock { report(.init(level: .warn, code: "unsupported_formatter", message: "Apple ListFormatter uses the platform's native list style", details: ["formatter": .string("formatList"), "locale": selected.map(MessagevisorValue.string) ?? .null])) }
        }
        return try formatList(values, locale: selected)
    }
    public func formatListToParts(_ values: [String], locale: String? = nil) throws -> [MessagevisorFormatPart] {
        let result = try formatList(values, locale: locale)
        reportSimplifiedParts("formatListToParts", locale: locale)
        return [.init(type: "literal", value: result)]
    }
    public func formatListToParts(_ values: [String], formatOptions: FormatOptions, locale: String? = nil) throws -> [MessagevisorFormatPart] {
        let selected = locale ?? formatOptions["locale"]?.stringValue
        let result = try formatList(values, formatOptions: formatOptions, locale: selected)
        reportSimplifiedParts("formatListToParts", locale: selected)
        return [.init(type: "literal", value: result)]
    }
    public func formatDisplayName(_ value: String, type: String, locale: String? = nil) throws -> String? {
        try storage.lock.withLock {
            let native = Locale(identifier: try currentLocale(locale))
            switch type { case "language": return native.localizedString(forLanguageCode: value); case "region": return native.localizedString(forRegionCode: value); case "script": return native.localizedString(forScriptCode: value); case "currency": return native.localizedString(forCurrencyCode: value); default: return value }
        }
    }
    public func formatDisplayName(_ value: String, formatOptions: FormatOptions, locale: String? = nil) throws -> String? {
        let selected = locale ?? formatOptions["locale"]?.stringValue
        if formatOptions["style"] != nil || formatOptions["languageDisplay"] != nil {
            storage.lock.withLock { report(.init(level: .warn, code: "unsupported_formatter", message: "Apple locale display names use the platform's native style", details: ["formatter": .string("formatDisplayName"), "locale": selected.map(MessagevisorValue.string) ?? .null])) }
        }
        let result = try formatDisplayName(value, type: formatOptions["type"]?.stringValue ?? "language", locale: selected)
        return formatOptions["fallback"]?.stringValue == "none" && result == nil ? nil : result ?? value
    }

    public func close() async throws {
        let task: Task<Void, Never> = storage.lock.withLock {
            if let closeTask { return closeTask }

            closed = true; emitter.clear(); moduleSubscriptions.removeAll(); moduleApis.removeAll()
            let subscriptions = parentSubscriptions.map(\.unsubscribe); parentSubscriptions.removeAll()
            let tasks = pendingModuleCleanupTasks; pendingModuleCleanupTasks.removeAll()
            let owned = parent == nil ? Array(modules.reversed()) : []
            owned.forEach(clearModuleResources); modules.removeAll()
            parent?.children.removeValue(forKey: childID)
            let task = Task { [weak self] in
                subscriptions.forEach { $0() }
                for task in tasks { await task.value }

                var errors: [Error] = []
                for module in owned {
                    guard let close = module.close else { continue }
                    do { try await close() }
                    catch {
                        errors.append(error)
                        self?.report(.init(level: .error, code: "module_close_error", message: "Module close failed", moduleName: module.name, originalError: error.localizedDescription))
                    }
                }
                self?.storage.lock.withLock { self?.closeErrors = errors }
            }
            // Publish while holding the shared lock. Even if the task starts immediately,
            // a close request from its callbacks cannot enter until this assignment completes.
            closeTask = task
            return task
        }
        await task.value
        let errors = storage.lock.withLock { closeErrors }
        if !errors.isEmpty { throw MessagevisorCloseError(errors: errors) }
    }

    private func resolveMessage(_ key: String, options: TranslateOptions) throws -> (translation: String, locale: String) {
        let selected = try currentLocale(options.locale), datafile = storage.datafiles[selected]
        if let datafile {
            let mergedContext = context.merging(options.context ?? [:]) { _, new in new }
            let provider = MessagevisorEvaluationDataProvider(context: mergedContext, segments: datafile.segments, resolveFlag: flagResolver(), resolveVariation: variationResolver())
            if let message = datafile.messages[key] {
                for override in message.overrides ?? [] where evaluateCondition(override.conditions, provider: provider) && evaluateGroupSegment(override.segments, provider: provider) {
                    report(.init(level: .debug, code: "message_override_matched", message: "Message override matched", details: ["locale": .string(selected), "messageKey": .string(key), "overrideKey": .string(override.key)]))
                    if message.deprecated == true { reportDeprecated(key, message, selected) }
                    return (override.translation, selected)
                }
                if message.deprecated == true, datafile.translations[key] != nil { reportDeprecated(key, message, selected) }
            }
            if let translation = datafile.translations[key] { return (translation, selected) }
        }
        if let translation = storage.defaultTranslations[selected]?[key] { return (translation, selected) }
        report(datafile == nil ? .init(level: .error, code: "missing_datafile", message: "Datafile not found for locale", details: ["locale": .string(selected), "messageKey": .string(key), "source": .string("translation")]) : .init(level: .error, code: "missing_translation", message: "Missing translation", details: ["locale": .string(selected), "messageKey": .string(key), "source": .string("translation")]))
        return (options.defaultTranslation ?? key, selected)
    }

    private func reportDeprecated(_ key: String, _ message: DatafileMessage, _ locale: String) {
        var details: [String: MessagevisorValue] = ["locale": .string(locale), "messageKey": .string(key), "source": .string("translation")]
        if let warning = message.deprecationWarning { details["deprecationWarning"] = .string(warning) }
        report(.init(level: .warn, code: "deprecated_message", message: "Deprecated message evaluated", details: details))
    }

    private func currentLocale(_ requested: String?) throws -> String {
        guard let selected = requested ?? locale else { report(.init(level: .error, code: "missing_locale", message: "Locale not set", details: ["locale": .null])); throw MessagevisorError("Locale not set") }
        return selected
    }

    private func evaluationFormats(_ options: EvaluationOptions, locale: String) -> FormatPresets {
        var formats = mergeFormats(mergeFormats(storage.defaultFormats[locale], storage.datafiles[locale]?.formats), options.formats)
        let selectedCurrency = options.currency ?? currency ?? "USD"
        var number = formats.number ?? [:]
        for key in Array(number.keys) {
            var value = number[key] ?? [:]
            if value["style"]?.stringValue == "currency" { value["currency"] = .string(options.currency ?? value["currency"]?.stringValue ?? selectedCurrency) }
            number[key] = value
        }
        formats.number = number
        let selectedTimeZone = options.timeZone ?? timeZone ?? storage.formatters.defaultTimeZone
        var date = formats.date ?? [:]
        for key in Array(date.keys) { var value = date[key] ?? [:]; value["timeZone"] = .string(options.timeZone ?? value["timeZone"]?.stringValue ?? selectedTimeZone); date[key] = value }
        formats.date = date
        var time = formats.time ?? [:]
        for key in Array(time.keys) { var value = time[key] ?? [:]; value["timeZone"] = .string(options.timeZone ?? value["timeZone"]?.stringValue ?? selectedTimeZone); time[key] = value }
        formats.time = time
        var range = formats.dateTimeRange ?? [:]
        for key in Array(range.keys) { var value = range[key] ?? [:]; value["timeZone"] = .string(options.timeZone ?? value["timeZone"]?.stringValue ?? selectedTimeZone); range[key] = value }
        formats.dateTimeRange = range
        return formats
    }

    private func runModules(_ initial: MessagevisorFormatPayload) throws -> String {
        var current = initial.translation
        for module in activeModules() where module.format != nil {
            var payload = initial; payload.translation = current
            do { if let next = try module.format!(payload, moduleApi(for: module)) { current = next } }
            catch { reportModuleFailure(error, module: module, hook: "format", payload: initial); throw error }
        }
        for module in activeModules() where module.transform != nil {
            do {
                if let next = try module.transform!(.init(translation: current, locale: initial.locale, source: initial.source, messageKey: initial.messageKey, meta: initial.meta), moduleApi(for: module)) { current = next }
            } catch { reportModuleFailure(error, module: module, hook: "transform", payload: initial); throw error }
        }
        return current
    }

    private func reportModuleFailure(_ error: Error, module: MessagevisorModule, hook: String, payload: MessagevisorFormatPayload) {
        report(.init(level: .error, code: "invalid_message", message: "Unable to \(hook) message", details: ["locale": .string(payload.locale), "messageKey": payload.messageKey.map(MessagevisorValue.string) ?? .null, "source": .string(payload.source.rawValue), "hook": .string(hook)], moduleName: module.name, originalError: error.localizedDescription))
    }

    private func activeModules() -> [MessagevisorModule] { parent?.activeModules() ?? modules }
    private func root() -> Messagevisor { parent?.root() ?? self }
    private func flagResolver() -> FlagResolver? { root().moduleFlagResolvers.last?.resolver ?? (hasOwnFlagResolver ? ownFlagResolver : parent?.flagResolver()) }
    private func variationResolver() -> VariationResolver? { root().moduleVariationResolvers.last?.resolver ?? (hasOwnVariationResolver ? ownVariationResolver : parent?.variationResolver()) }

    private func moduleApi(for module: MessagevisorModule) -> MessagevisorModuleApi {
        let owner = root(); if let api = moduleApis[module.id] { return api }
        let moduleID = module.id, moduleName = module.name
        let state = owner.moduleStates[moduleID] ?? CallbackState()
        if owner.moduleStates[moduleID] == nil { state.active = false }
        let api = MessagevisorModuleApi(
            setFlagResolver: { [weak owner] resolver in owner?.storage.lock.withLock { guard state.active else { return }; owner?.moduleFlagResolvers.removeAll { $0.moduleID == moduleID }; if let resolver { owner?.moduleFlagResolvers.append(.init(moduleID: moduleID, resolver: resolver)) } } },
            setVariationResolver: { [weak owner] resolver in owner?.storage.lock.withLock { guard state.active else { return }; owner?.moduleVariationResolvers.removeAll { $0.moduleID == moduleID }; if let resolver { owner?.moduleVariationResolvers.append(.init(moduleID: moduleID, resolver: resolver)) } } },
            getRevision: { [weak self] locale in guard let self else { throw MessagevisorError("Messagevisor instance no longer exists") }; return try self.getRevision(locale: locale) },
            onDiagnostic: { [weak self] handler, options in
                guard let self else { return {} }
                let id = UUID()
                self.storage.lock.withLock {
                    guard state.active, !self.closed else { return }
                    self.moduleSubscriptions.append(.init(id: id, moduleID: moduleID, handler: handler, logLevel: options.logLevel))
                }
                return { [weak self] in self?.storage.lock.withLock { self?.moduleSubscriptions.removeAll { $0.id == id } } }
            },
            reportDiagnostic: { [weak self] diagnostic in self?.storage.lock.withLock {
                guard state.active, self?.closed == false else { return }
                self?.report(.init(level: diagnostic.level, code: diagnostic.code, message: diagnostic.message, details: diagnostic.details, module: moduleName, originalError: diagnostic.originalError), sourceModuleID: moduleID)
            } }
        )
        moduleApis[module.id] = api; return api
    }

    private func clearModuleResources(_ module: MessagevisorModule) {
        moduleStates.removeValue(forKey: module.id)?.active = false
        clearLocalModuleResources(module.id)
        for child in children.values { child.value?.clearLocalModuleResources(module.id) }
        children = children.filter { $0.value.value != nil }
    }

    private func clearLocalModuleResources(_ moduleID: UUID) {
        moduleSubscriptions.removeAll { $0.moduleID == moduleID }; moduleFlagResolvers.removeAll { $0.moduleID == moduleID }
        moduleVariationResolvers.removeAll { $0.moduleID == moduleID }; moduleApis.removeValue(forKey: moduleID)
    }

    private func closeModule(_ module: MessagevisorModule) async throws {
        guard let close = module.close else { return }
        do { try await close() }
        catch { storage.lock.withLock { report(.init(level: .error, code: "module_close_error", message: "Module close failed", moduleName: module.name, originalError: error.localizedDescription)) }; throw error }
    }

    private func report(_ diagnostic: MessagevisorDiagnostic, sourceModuleID: UUID? = nil) {
        storage.lock.withLock {
            reportLocked(diagnostic, sourceModuleID: sourceModuleID)
        }
    }

    private func reportLocked(_ diagnostic: MessagevisorDiagnostic, sourceModuleID: UUID? = nil) {
        for subscription in moduleSubscriptions where subscription.moduleID != sourceModuleID && shouldDeliver(subscription.logLevel, diagnostic.level) {
            do { try subscription.handler(diagnostic) } catch { fputs("\(error)\n", stderr) }
        }
        if shouldDeliver(logLevel, diagnostic.level) {
            if let diagnosticHandler { do { try diagnosticHandler(diagnostic) } catch { fputs("\(error)\n", stderr) } }
            else {
                fputs("[Messagevisor] [\(diagnostic.level)] \(diagnostic.code): \(diagnostic.message)\n", stderr)
            }
        }
        if diagnostic.level == .error, !closed {
            let snapshot = getSnapshot(); emitter.emit(.init(type: .error, version: version, snapshot: snapshot, previousSnapshot: snapshot, details: .error(diagnostic: diagnostic)))
        }
    }

    private func emit(_ type: MessagevisorEventName, _ previous: MessagevisorSnapshot, _ details: MessagevisorEventDetails) {
        guard !closed else { return }; version += 1
        let event = MessagevisorEvent(type: type, version: version, snapshot: getSnapshot(), previousSnapshot: previous, details: details)
        emitter.emit(event); emitter.emit(.init(type: .change, version: version, snapshot: event.snapshot, previousSnapshot: previous, details: .change(source: type, details: details)))
    }

    private func named(_ preset: String?, type: String, values: [String: FormatOptions]?, locale: String) throws -> FormatOptions {
        guard let preset else { return [:] }
        guard let value = values?[preset] else { report(.init(level: .error, code: "missing_format", message: "Named format preset not found", details: ["locale": .string(locale), "type": .string(type), "preset": .string(preset)])); return [:] }
        return value
    }

    private func reportSimplifiedParts(_ formatter: String, locale requested: String?) {
        storage.lock.withLock {
            report(.init(level: .warn, code: "unsupported_formatter", message: "Apple Foundation exposes a simplified formatter-parts representation", details: ["formatter": .string(formatter), "locale": (requested ?? locale).map(MessagevisorValue.string) ?? .null]))
        }
    }

    private func formatDateValue(_ value: Date, type: String, preset: String?, options: EvaluationOptions) throws -> String {
        storage.lock.lock(); defer { storage.lock.unlock() }
        let selected = try currentLocale(options.locale), formats = evaluationFormats(options, locale: selected)
        let values = type == "date" ? formats.date : formats.time
        let formatOptions = try named(preset, type: type, values: values, locale: selected)
        let zone = options.timeZone ?? formatOptions["timeZone"]?.stringValue ?? timeZone ?? storage.formatters.defaultTimeZone
        try validateTimeZone(zone, type: type, locale: selected, options: formatOptions)
        try validateDate(value, type: type, locale: selected, options: formatOptions)
        return storage.formatters.date(locale: selected, options: formatOptions, timeZone: zone, kind: type).string(from: value)
    }

    private func validateDate(_ value: Date, type: String, locale: String, options: FormatOptions) throws {
        guard value.timeIntervalSince1970.isFinite else { try invalidFormat(type: type, locale: locale, options: options, reason: "Date must be finite") }
    }

    private func formatNumberValue(_ value: Double, formatOptions: FormatOptions, locale: String, currency: String?) throws -> String {
        if formatOptions["style"]?.stringValue == "currency" {
            let code = formatOptions["currency"]?.stringValue ?? currency ?? "USD"
            guard code.range(of: "^[A-Za-z]{3}$", options: .regularExpression) != nil else {
                try invalidFormat(type: "number", locale: locale, options: formatOptions, reason: "Currency must be a three-letter code")
            }
        }
        if formatOptions["notation"]?.stringValue == "compact" {
            if formatOptions["compactDisplay"]?.stringValue == "long" {
                report(.init(level: .warn, code: "unsupported_formatter", message: "Apple compact number formatting uses the platform's native compact style", details: ["formatter": .string("formatNumber"), "locale": .string(locale)]))
            }
            if #available(macOS 12, iOS 15, tvOS 15, watchOS 8, visionOS 1, *) {
                let localeIdentifier = formatOptions["numberingSystem"]?.stringValue.map { "\(locale)@numbers=\($0)" } ?? locale
                return value.formatted(.number.notation(.compactName).rounded(rule: .toNearestOrAwayFromZero).locale(Locale(identifier: localeIdentifier)))
            }
            report(.init(level: .warn, code: "unsupported_formatter", message: "Compact number formatting requires a newer Apple runtime", details: ["formatter": .string("formatNumber"), "locale": .string(locale)]))
        }
        if formatOptions["roundingPriority"] != nil || formatOptions["useGrouping"]?.stringValue == "min2" {
            report(.init(level: .warn, code: "unsupported_formatter", message: "Apple NumberFormatter does not expose every ECMA-402 number option", details: ["formatter": .string("formatNumber"), "locale": .string(locale)]))
        }
        var resolved = formatOptions
        resolved["__negative"] = .bool(value < 0)
        resolved["__nonZero"] = .bool(value != 0)
        resolved["__integer"] = .bool(value.rounded() == value)
        let formatter = storage.formatters.number(locale: locale, options: resolved, currency: currency)
        guard let result = formatter.string(from: NSNumber(value: value)) else {
            try invalidFormat(type: "number", locale: locale, options: formatOptions, reason: "Foundation rejected the number format")
        }
        return result
    }

    private func validateTimeZone(_ identifier: String?, type: String, locale: String, options: FormatOptions) throws {
        guard let identifier else { return }
        guard TimeZone(identifier: identifier) != nil else {
            try invalidFormat(type: type, locale: locale, options: options, reason: "Unknown time zone: \(identifier)")
        }
    }

    private func invalidFormat(type: String, locale: String, options: FormatOptions, reason: String) throws -> Never {
        let error = MessagevisorError(reason)
        report(.init(level: .error, code: "invalid_format", message: "Invalid format options", details: ["locale": .string(locale), "type": .string(type), "options": .object(options)], originalError: error.localizedDescription))
        throw error
    }
}

public func createMessagevisor(_ options: MessagevisorOptions = .init()) -> Messagevisor { Messagevisor(options: options) }

private func mergeDatafile(_ old: DatafileContent, _ new: DatafileContent) -> DatafileContent {
    .init(schemaVersion: new.schemaVersion, messagevisorVersion: new.messagevisorVersion, revision: new.revision, target: new.target, locale: new.locale, direction: new.direction ?? old.direction, formats: old.formats == nil && new.formats == nil ? nil : mergeFormats(old.formats, new.formats, replacePresets: true), segments: old.segments.merging(new.segments) { _, value in value }, messages: old.messages.merging(new.messages) { _, value in value }, translations: old.translations.merging(new.translations) { _, value in value })
}

private func relativeInterval(_ value: Double, _ unit: Calendar.Component) -> TimeInterval {
    switch unit { case .second: return value; case .minute: return value * 60; case .hour: return value * 3600; case .day: return value * 86400; case .weekOfYear: return value * 604800; case .month: return value * 2629800; case .year: return value * 31557600; default: return value }
}

private func dateStyle(_ value: String) -> DateIntervalFormatter.Style {
    switch value { case "full": return .full; case "long": return .long; case "medium": return .medium; default: return .short }
}

private extension NSRecursiveLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() }
}
