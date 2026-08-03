import Foundation
import Messagevisor

public struct MissingTranslationPayload: Sendable {
    public var messageKey: String
    public var locale: String?
    public var revision: String?
    public var source: MessagevisorTranslationSource?
    public var diagnostic: MessagevisorDiagnostic
}

public struct MissingTranslationsModuleOptions: Sendable {
    public var name: String
    public var dedupe: Bool
    public var handler: @Sendable (MissingTranslationPayload) -> Void
    public init(name: String = "missing-translations", dedupe: Bool = false, handler: @escaping @Sendable (MissingTranslationPayload) -> Void) {
        self.name = name; self.dedupe = dedupe; self.handler = handler
    }
}

public func createMissingTranslationsModule(_ options: MissingTranslationsModuleOptions) -> MessagevisorModule {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var seen = Set<String>()
        private var unsubscribe: MessagevisorUnsubscribe?

        func install(_ unsubscribe: @escaping MessagevisorUnsubscribe) {
            lock.lock(); defer { lock.unlock() }
            self.unsubscribe = unsubscribe
        }

        func shouldDeliver(_ key: String, dedupe: Bool) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if dedupe && seen.contains(key) { return false }
            seen.insert(key)
            return true
        }

        func close() {
            let callback: MessagevisorUnsubscribe? = {
                lock.lock(); defer { lock.unlock() }
                let callback = unsubscribe
                unsubscribe = nil
                return callback
            }()
            callback?()
        }
    }
    let state = State()
    return MessagevisorModule(
        name: options.name,
        setup: { api in
            state.install(api.onDiagnostic({ diagnostic in
                guard diagnostic.code == "missing_translation", let key = diagnostic.details["messageKey"]?.stringValue else { return }
                let locale = diagnostic.details["locale"]?.stringValue
                let source = diagnostic.details["source"]?.stringValue.flatMap(MessagevisorTranslationSource.init(rawValue:))
                let revision = locale.flatMap { try? api.getRevision($0) }
                let dedupeKey = [key, locale ?? "", revision ?? "", source?.rawValue ?? ""].joined(separator: "\u{0}")
                guard state.shouldDeliver(dedupeKey, dedupe: options.dedupe) else { return }
                options.handler(.init(messageKey: key, locale: locale, revision: revision, source: source, diagnostic: diagnostic))
            }, .init(logLevel: .error)))
        },
        close: { state.close() }
    )
}
