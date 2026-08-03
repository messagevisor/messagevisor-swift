import Foundation

public enum MessagevisorLogLevel: Int, Codable, CaseIterable, Sendable {
    case fatal = 0
    case error = 1
    case warn = 2
    case info = 3
    case debug = 4
}

public struct MessagevisorDiagnostic: Sendable {
    public var level: MessagevisorLogLevel
    public var code: String
    public var message: String
    public var details: [String: MessagevisorValue]
    public var module: String?
    public var moduleName: String?
    public var originalError: String?

    public init(level: MessagevisorLogLevel, code: String, message: String, details: [String: MessagevisorValue] = [:], module: String? = nil, moduleName: String? = nil, originalError: String? = nil) {
        self.level = level; self.code = code; self.message = message; self.details = details
        self.module = module; self.moduleName = moduleName; self.originalError = originalError
    }
}

public typealias MessagevisorDiagnosticHandler = @Sendable (MessagevisorDiagnostic) throws -> Void
public typealias MessagevisorUnsubscribe = @Sendable () -> Void
public typealias MessagevisorModuleRemoval = @Sendable () async throws -> Void

func shouldDeliver(_ current: MessagevisorLogLevel, _ diagnostic: MessagevisorLogLevel) -> Bool {
    current.rawValue >= diagnostic.rawValue
}

public struct MessagevisorError: Error, LocalizedError, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

public struct MessagevisorCloseError: Error, LocalizedError, CustomStringConvertible, @unchecked Sendable {
    public let message = "One or more Messagevisor modules failed to close."
    public let errors: [Error]
    public init(errors: [Error]) { self.errors = errors }
    public var description: String { message }
    public var errorDescription: String? { message }
}
