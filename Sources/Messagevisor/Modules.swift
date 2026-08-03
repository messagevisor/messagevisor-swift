import Foundation

public enum MessagevisorTranslationSource: String, Sendable { case translation, formatMessage }

public struct MessagevisorFormatPayload: Sendable {
    public var translation: String
    public var values: MessagevisorValues
    public var locale: String
    public var source: MessagevisorTranslationSource
    public var messageKey: String?
    public var meta: [String: MessagevisorValue]?
    public var formats: FormatPresets
    public var moduleOptions: [String: MessagevisorValue]?
    public var currency: String?
    public var timeZone: String?
}

public struct MessagevisorTransformPayload: Sendable {
    public var translation: String
    public var locale: String
    public var source: MessagevisorTranslationSource
    public var messageKey: String?
    public var meta: [String: MessagevisorValue]?
}

public struct MessagevisorModuleDiagnosticOptions: Sendable {
    public var logLevel: MessagevisorLogLevel
    public init(logLevel: MessagevisorLogLevel = .info) { self.logLevel = logLevel }
}

public struct MessagevisorModuleReportedDiagnostic: Sendable {
    public var level: MessagevisorLogLevel
    public var code: String
    public var message: String
    public var details: [String: MessagevisorValue]
    public var originalError: String?
    public init(level: MessagevisorLogLevel, code: String, message: String, details: [String: MessagevisorValue] = [:], originalError: String? = nil) {
        self.level = level; self.code = code; self.message = message; self.details = details; self.originalError = originalError
    }
}

public struct MessagevisorModuleApi: Sendable {
    public let setFlagResolver: @Sendable (FlagResolver?) -> Void
    public let setVariationResolver: @Sendable (VariationResolver?) -> Void
    public let getRevision: @Sendable (String?) throws -> String
    public let onDiagnostic: @Sendable (@escaping MessagevisorDiagnosticHandler, MessagevisorModuleDiagnosticOptions) -> MessagevisorUnsubscribe
    public let reportDiagnostic: @Sendable (MessagevisorModuleReportedDiagnostic) -> Void

    public init(
        setFlagResolver: @escaping @Sendable (FlagResolver?) -> Void,
        setVariationResolver: @escaping @Sendable (VariationResolver?) -> Void,
        getRevision: @escaping @Sendable (String?) throws -> String,
        onDiagnostic: @escaping @Sendable (@escaping MessagevisorDiagnosticHandler, MessagevisorModuleDiagnosticOptions) -> MessagevisorUnsubscribe,
        reportDiagnostic: @escaping @Sendable (MessagevisorModuleReportedDiagnostic) -> Void
    ) {
        self.setFlagResolver = setFlagResolver; self.setVariationResolver = setVariationResolver
        self.getRevision = getRevision; self.onDiagnostic = onDiagnostic; self.reportDiagnostic = reportDiagnostic
    }
}

public struct MessagevisorModule: Sendable {
    let id = UUID()
    public var name: String?
    public var setup: (@Sendable (MessagevisorModuleApi) throws -> Void)?
    /// Return `nil` to leave the current translation unchanged.
    public var format: (@Sendable (MessagevisorFormatPayload, MessagevisorModuleApi) throws -> String?)?
    /// Return `nil` to leave the current translation unchanged.
    public var transform: (@Sendable (MessagevisorTransformPayload, MessagevisorModuleApi) throws -> String?)?
    public var close: (@Sendable () async throws -> Void)?

    public init(name: String? = nil, setup: (@Sendable (MessagevisorModuleApi) throws -> Void)? = nil, format: (@Sendable (MessagevisorFormatPayload, MessagevisorModuleApi) throws -> String?)? = nil, transform: (@Sendable (MessagevisorTransformPayload, MessagevisorModuleApi) throws -> String?)? = nil, close: (@Sendable () async throws -> Void)? = nil) {
        self.name = name; self.setup = setup; self.format = format; self.transform = transform; self.close = close
    }
}
