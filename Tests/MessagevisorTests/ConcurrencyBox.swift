import Foundation

final class ConcurrencyBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: T

    init(_ value: T) { storedValue = value }

    var value: T {
        lock.lock(); defer { lock.unlock() }
        return storedValue
    }

    func mutate(_ body: (inout T) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&storedValue)
    }
}
