import Foundation

public enum MessagevisorEventName: String, CaseIterable, Sendable {
    case change
    case error
    case datafileSet = "datafile_set"
    case localeSet = "locale_set"
    case contextSet = "context_set"
    case currencySet = "currency_set"
    case timeZoneSet = "timeZone_set"
}

public struct MessagevisorSnapshot: Equatable, Sendable {
    public var version: Int
    public var locale: String?
    public var direction: String?
    public var context: MessagevisorContext
    public var currency: String?
    public var timeZone: String?
    public var datafileLocales: [String]
    public var datafileRevisionsByLocale: [String: String]
}

public indirect enum MessagevisorEventDetails: Sendable {
    case datafileSet(datafile: DatafileContent, locale: String, activeLocale: String?, previousLocale: String?, replaced: Bool)
    case localeSet(locale: String, previousLocale: String?)
    case contextSet(context: MessagevisorContext, previousContext: MessagevisorContext, replaced: Bool)
    case currencySet(currency: String, previousCurrency: String?)
    case timeZoneSet(timeZone: String, previousTimeZone: String?)
    case error(diagnostic: MessagevisorDiagnostic)
    case change(source: MessagevisorEventName, details: MessagevisorEventDetails)
}

public struct MessagevisorEvent: Sendable {
    public var type: MessagevisorEventName
    public var version: Int
    public var snapshot: MessagevisorSnapshot
    public var previousSnapshot: MessagevisorSnapshot
    public var details: MessagevisorEventDetails
}

public typealias MessagevisorEventCallback = @Sendable (MessagevisorEvent) throws -> Void

final class MessagevisorEmitter: @unchecked Sendable {
    private struct Listener: Sendable { let id: UUID; let callback: MessagevisorEventCallback }
    private var listeners: [MessagevisorEventName: [Listener]] = [:]

    func on(_ name: MessagevisorEventName, _ callback: @escaping MessagevisorEventCallback) -> MessagevisorUnsubscribe {
        let id = UUID(); listeners[name, default: []].append(.init(id: id, callback: callback))
        return { [weak self] in self?.listeners[name]?.removeAll { $0.id == id } }
    }

    func emit(_ event: MessagevisorEvent) {
        for listener in listeners[event.type] ?? [] {
            do { try listener.callback(event) } catch { fputs("\(error)\n", stderr) }
        }
    }

    func clear() { listeners.removeAll() }
}
