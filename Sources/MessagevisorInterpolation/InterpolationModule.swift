import Foundation
import Messagevisor

public struct InterpolationModuleOptions: Sendable {
    public var name: String
    public var pattern: String
    public init(name: String = "interpolation", pattern: String = #"\{([A-Za-z_][A-Za-z0-9_]*)\}"#) {
        self.name = name; self.pattern = pattern
    }
}

public func createInterpolationModule(_ options: InterpolationModuleOptions = .init()) -> MessagevisorModule {
    MessagevisorModule(name: options.name, format: { payload, _ in
        guard let expression = try? NSRegularExpression(pattern: options.pattern) else { return payload.translation }
        var result = payload.translation
        let matches = expression.matches(in: result, range: NSRange(result.startIndex..<result.endIndex, in: result)).reversed()
        for match in matches where match.numberOfRanges > 1 {
            guard let whole = Range(match.range(at: 0), in: result), let nameRange = Range(match.range(at: 1), in: result) else { continue }
            let name = String(result[nameRange]), value = payload.values[name]
            guard let value, value.stringValue != nil || value.numberValue != nil || value.boolValue != nil else { continue }
            result.replaceSubrange(whole, with: value.displayValue)
        }
        return result
    })
}
