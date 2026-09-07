import Foundation
import CoreFoundation
import Messagevisor
import MessagevisorICU
import MessagevisorInterpolation

let messagevisorSwiftVersion = "0.2.0"

@main
enum MessagevisorSwiftCLI {
    static func main() async {
        do {
            let code = try await run(Array(CommandLine.arguments.dropFirst()))
            Foundation.exit(Int32(code))
        } catch {
            fputs("messagevisor-swift: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    static func run(_ arguments: [String]) async throws -> Int {
        guard let command = arguments.first else { printUsage(); return 2 }
        let options = CLIOptions(Array(arguments.dropFirst()))
        switch command {
        case "test": return try runTests(options)
        case "evaluate": return try runEvaluate(options)
        case "benchmark": return try runBenchmark(options)
        case "examples": return try runExamples(options)
        case "--version", "version": print(messagevisorSwiftVersion); return 0
        default: printUsage(); return 2
        }
    }

    static func printUsage() {
        print("Usage: messagevisor-swift <test|evaluate|benchmark|examples> [options]")
    }

    static func modules(_ options: CLIOptions) -> [MessagevisorModule] {
        var result: [MessagevisorModule] = []
        if options.flag("withInterpolationModule") { result.append(createInterpolationModule()) }
        if options.flag("withIcuModule") { result.append(createICUModule()) }
        return result
    }

    static func runTests(_ options: CLIOptions) throws -> Int {
        let project = options.projectPath
        var args = ["list", "--tests", "--applyMatrix", "--json"]
        if let key = options.value("keyPattern") { args.append("--keyPattern=\(key)") }
        let tests = try jsonArray(runMessagevisor(project, args))
        let segments = try loadSegments(project)
        let assertionPattern: NSRegularExpression?
        if let pattern = options.value("assertionPattern") { assertionPattern = try NSRegularExpression(pattern: pattern) }
        else { assertionPattern = nil }
        let defaultTarget = options.value("target") ?? "swift"
        let installedModules = modules(options)
        var cache: [String: DatafileContent] = [:]
        var passedTests = 0, failedTests = 0, passedAssertions = 0, failedAssertions = 0

        for test in tests {
            var failed = false, lines: [String] = []
            for assertion in arrayOfObjects(test["assertions"]) {
                let description = [string(test["key"]), string(assertion["description"])].compactMap { $0 }.joined(separator: " / ")
                if let assertionPattern {
                    let range = NSRange(description.startIndex..<description.endIndex, in: description)
                    if assertionPattern.firstMatch(in: description, range: range) == nil { continue }
                }
                let failures: [String]
                do { failures = try evaluateAssertion(project: project, test: test, assertion: assertion, segments: segments, defaultTarget: defaultTarget, modules: installedModules, cache: &cache, normalizeSpaces: options.flag("normalizeSpaces")) }
                catch { failures = ["Swift evaluation failed: \(error)"] }
                if failures.isEmpty { passedAssertions += 1; lines.append("  ✓ \(description)") }
                else { failed = true; failedAssertions += 1; lines.append("  x \(description)"); lines += failures.map { "    \($0)" } }
            }
            if failed { failedTests += 1 } else { passedTests += 1 }
            if !options.flag("quiet") && (!options.flag("onlyFailures") || failed) { print("\nTesting: \(string(test["key"]) ?? "unknown")"); lines.forEach { print($0) } }
        }
        print("\nTest specs: \(passedTests) passed, \(failedTests) failed")
        print("Assertions: \(passedAssertions) passed, \(failedAssertions) failed")
        return failedTests == 0 ? 0 : 1
    }

    static func evaluateAssertion(project: URL, test: [String: Any], assertion: [String: Any], segments: [String: Segment], defaultTarget: String, modules: [MessagevisorModule], cache: inout [String: DatafileContent], normalizeSpaces: Bool) throws -> [String] {
        var failures: [String] = []
        let context = values(assertion["context"])
        if let segment = string(assertion["segment"]) ?? string(test["segment"]) {
            let actual = evaluateSegment(segment, provider: .init(context: context, segments: segments))
            if actual != bool(assertion["expectedToMatch"]) { failures.append("Segment mismatch: expected \(bool(assertion["expectedToMatch"])), got \(actual)") }
            return failures
        }

        let target = string(assertion["target"]) ?? string(test["target"]) ?? defaultTarget
        guard let locale = string(assertion["locale"]) ?? string(test["locale"]) else { return ["Assertion has no locale"] }
        let key = "\(target)\u{0}\(locale)"
        let datafile: DatafileContent
        if let existing = cache[key] { datafile = existing }
        else { datafile = try buildDatafile(project, target: target, locale: locale); cache[key] = datafile }

        for expected in strings(assertion["expectedToIncludeMessages"]) where datafile.translations[expected] == nil { failures.append("Expected datafile to include message \(expected)") }
        for expected in strings(assertion["expectedToNotIncludeMessages"]) where datafile.translations[expected] != nil { failures.append("Expected datafile not to include message \(expected)") }
        if let expectedFormats = assertion["expectedFormats"] {
            let actual = try jsonObject(datafile.formats ?? FormatPresets())
            if !jsonContains(actual, expectedFormats) { failures.append("Formats mismatch: expected subset \(renderJSON(expectedFormats))") }
        }
        guard assertion["expectedTranslation"] != nil else { return failures }

        let flags = object(assertion["withFlags"]).mapValues { bool($0) }
        let variations = object(assertion["withVariations"]).compactMapValues { string($0) }
        let sdk = createMessagevisor(.init(datafile: datafile, context: context, resolveFlag: { key, _ in flags[key] ?? false }, resolveVariation: { key, _ in variations[key] }, logLevel: .fatal, modules: modules))
        let evaluation = EvaluationOptions(locale: locale, currency: string(assertion["currency"]), timeZone: string(assertion["timeZone"]), formats: formatPresets(assertion["formats"]))
        let actual: String
        if let message = string(assertion["message"]) ?? string(test["message"]) {
            actual = try sdk.translate(message, values: values(assertion["values"]), options: .init(locale: locale, currency: evaluation.currency, timeZone: evaluation.timeZone, formats: evaluation.formats, context: context))
        } else if let raw = string(assertion["rawMessage"]) {
            actual = try sdk.formatMessage(raw, values: values(assertion["values"]), options: evaluation)
        } else { return failures + ["Translation assertion has no message or rawMessage"] }
        let runtimeExpected = string(object(assertion["expectedByRuntime"])["swift"])
        let expected = runtimeExpected ?? string(assertion["expectedTranslation"]) ?? ""
        let comparedActual = normalizeSpaces ? normalizeSpaceCharacters(actual) : actual
        let comparedExpected = normalizeSpaces ? normalizeSpaceCharacters(expected) : expected
        if comparedActual != comparedExpected { failures.append("Translation mismatch: expected \(String(reflecting: expected)), got \(String(reflecting: actual))") }
        return failures
    }

    static func runEvaluate(_ options: CLIOptions) throws -> Int {
        let project = options.projectPath, context = values(options.value("context").flatMap(parseJSON)), messageValues = values(options.value("values").flatMap(parseJSON))
        if let segment = options.value("segment") { print(evaluateSegment(segment, provider: .init(context: context, segments: try loadSegments(project)))); return 0 }
        guard let locale = options.value("locale") else { throw MessagevisorError("pass --locale=<locale>") }
        let target = options.value("target") ?? "swift", sdk = createMessagevisor(.init(datafile: try buildDatafile(project, target: target, locale: locale), context: context, logLevel: .fatal, modules: modules(options)))
        let result: String
        if let message = options.value("message") { result = try sdk.translate(message, values: messageValues, options: .init(context: context)) }
        else if let raw = options.value("rawMessage") { result = try sdk.formatMessage(raw, values: messageValues) }
        else { throw MessagevisorError("pass --message, --rawMessage, or --segment") }
        if options.flag("json") { print(renderJSON(["translation": result])) } else { print(result) }
        return 0
    }

    static func runBenchmark(_ options: CLIOptions) throws -> Int {
        guard let locale = options.value("locale") else { throw MessagevisorError("pass --locale=<locale>") }
        let target = options.value("target") ?? "swift", iterations = max(1, Int(options.value("n") ?? "1000") ?? 1000)
        let context = values(options.value("context").flatMap(parseJSON)), messageValues = values(options.value("values").flatMap(parseJSON))
        let sdk = createMessagevisor(.init(datafile: try buildDatafile(options.projectPath, target: target, locale: locale), context: context, logLevel: .fatal, modules: modules(options)))
        let start = DispatchTime.now().uptimeNanoseconds; var result = ""
        for _ in 0..<iterations {
            if let message = options.value("message") { result = try sdk.translate(message, values: messageValues) }
            else if let raw = options.value("rawMessage") { result = try sdk.formatMessage(raw, values: messageValues) }
            else { throw MessagevisorError("pass --message or --rawMessage") }
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        print(renderJSON(["target": target, "locale": locale, "iterations": iterations, "durationMs": Double(elapsed) / 1_000_000, "averageMicros": Double(elapsed) / Double(iterations) / 1_000, "lastResult": result]))
        return 0
    }

    static func runExamples(_ options: CLIOptions) throws -> Int {
        var args = ["examples", "--json"]
        if let locale = options.value("locale") { args.append("--locale=\(locale)") }
        let payload = object(try JSONSerialization.jsonObject(with: Data(runMessagevisor(options.projectPath, args).utf8)))
        let examples = arrayOfObjects(payload["locales"]) + arrayOfObjects(payload["messages"])
        let target = options.value("target") ?? "swift", installedModules = modules(options)
        var cache: [String: DatafileContent] = [:], passed = 0, failed = 0

        for example in examples {
            guard let locale = string(example["locale"]) else { continue }
            let key = "\(target)\u{0}\(locale)"
            let datafile: DatafileContent
            if let existing = cache[key] { datafile = existing }
            else { datafile = try buildDatafile(options.projectPath, target: target, locale: locale); cache[key] = datafile }
            let context = values(example["context"]), messageValues = values(example["values"])
            let evaluation = EvaluationOptions(locale: locale, currency: string(example["currency"]), timeZone: string(example["timeZone"]))
            let sdk = createMessagevisor(.init(datafile: datafile, context: context, logLevel: .fatal, modules: installedModules))

            do {
                let actual: String
                if let message = string(example["message"]) {
                    actual = try sdk.translate(message, values: messageValues, options: .init(locale: locale, currency: evaluation.currency, timeZone: evaluation.timeZone, context: context))
                } else if let rawMessage = string(example["rawMessage"]) {
                    actual = try sdk.formatMessage(rawMessage, values: messageValues, options: evaluation)
                } else { continue }
                let expected = string(object(example["expectedByRuntime"])["swift"]) ?? string(example["evaluatedTranslation"]) ?? ""
                let comparedActual = options.flag("normalizeSpaces") ? normalizeSpaceCharacters(actual) : actual
                let comparedExpected = options.flag("normalizeSpaces") ? normalizeSpaceCharacters(expected) : expected
                if comparedActual != comparedExpected {
                    failed += 1
                    print("x \(exampleLabel(example)): expected \(String(reflecting: expected)), got \(String(reflecting: actual))")
                } else {
                    passed += 1
                    if !options.flag("onlyFailures") { print("✓ \(exampleLabel(example))") }
                }
            } catch {
                failed += 1; print("x \(exampleLabel(example)): \(error)")
            }
        }
        print("\nExamples: \(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}

struct CLIOptions {
    private var values: [String: [String]] = [:]
    init(_ arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") || argument == "-n" else { index += 1; continue }
            let trimmed = argument == "-n" ? "n" : String(argument.dropFirst(2))
            if let separator = trimmed.firstIndex(of: "=") { values[String(trimmed[..<separator]), default: []].append(String(trimmed[trimmed.index(after: separator)...])) }
            else if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") { values[trimmed, default: []].append(arguments[index + 1]); index += 1 }
            else { values[trimmed, default: []].append("true") }
            index += 1
        }
    }
    func value(_ key: String) -> String? { values[key]?.last }
    func flag(_ key: String) -> Bool { value(key) == "true" }
    var projectPath: URL { URL(fileURLWithPath: value("projectDirectoryPath") ?? FileManager.default.currentDirectoryPath).standardizedFileURL }
}

private func runMessagevisor(_ project: URL, _ arguments: [String]) throws -> String {
    let process = Process(); process.currentDirectoryURL = project; process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = ["npx", "messagevisor"] + arguments
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("messagevisor-swift-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stdoutURL = directory.appendingPathComponent("stdout"), stderrURL = directory.appendingPathComponent("stderr")
    FileManager.default.createFile(atPath: stdoutURL.path, contents: nil); FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
    let stdoutHandle = try FileHandle(forWritingTo: stdoutURL), stderrHandle = try FileHandle(forWritingTo: stderrURL)
    defer { try? stdoutHandle.close(); try? stderrHandle.close() }
    process.standardOutput = stdoutHandle; process.standardError = stderrHandle
    try process.run(); process.waitUntilExit()
    try stdoutHandle.synchronize(); try stderrHandle.synchronize()
    let stdout = String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self)
    let stderrText = String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self)
    guard process.terminationStatus == 0 else { throw MessagevisorError("npx messagevisor \(arguments.joined(separator: " ")) failed:\n\(stderrText)\n\(stdout.prefix(1000))") }
    return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func buildDatafile(_ project: URL, target: String, locale: String) throws -> DatafileContent { try .fromJSON(runMessagevisor(project, ["build", "--json", "--target=\(target)", "--locale=\(locale)"])) }
private func loadSegments(_ project: URL) throws -> [String: Segment] {
    let data = Data(try runMessagevisor(project, ["list", "--segments", "--json"]).utf8), list = try JSONDecoder().decode([Segment].self, from: data)
    var result: [String: Segment] = [:]
    for segment in list { if let key = segment.key { result[key] = segment } }
    return result
}

private func parseJSON(_ value: String) -> Any? { try? JSONSerialization.jsonObject(with: Data(value.utf8)) }
private func jsonArray(_ value: String) throws -> [[String: Any]] { arrayOfObjects(try JSONSerialization.jsonObject(with: Data(value.utf8))) }
private func object(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
private func arrayOfObjects(_ value: Any?) -> [[String: Any]] { value as? [[String: Any]] ?? [] }
private func string(_ value: Any?) -> String? { value is NSNull ? nil : value as? String }
private func bool(_ value: Any?) -> Bool { value as? Bool ?? false }
private func strings(_ value: Any?) -> [String] { value as? [String] ?? [] }
private func values(_ value: Any?) -> MessagevisorValues { object(value).mapValues(toValue) }
private func toValue(_ value: Any) -> MessagevisorValue {
    if value is NSNull { return .null }
    if let value = value as? NSNumber {
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return .bool(value.boolValue) }
        return floor(value.doubleValue) == value.doubleValue ? .int(value.intValue) : .double(value.doubleValue)
    }
    if let value = value as? String { return .string(value) }; if let value = value as? [Any] { return .array(value.map(toValue)) }
    if let value = value as? [String: Any] { return .object(value.mapValues(toValue)) }; return .string(String(describing: value))
}
private func formatPresets(_ value: Any?) -> FormatPresets? { guard let value else { return nil }; return try? JSONDecoder().decode(FormatPresets.self, from: JSONSerialization.data(withJSONObject: value)) }
private func jsonObject<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
private func jsonContains(_ actual: Any, _ expected: Any) -> Bool {
    if let expected = expected as? [String: Any], let actual = actual as? [String: Any] {
        return expected.allSatisfy { key, value in actual[key].map { jsonContains($0, value) } ?? false }
    }
    if let expected = expected as? [Any], let actual = actual as? [Any] {
        return expected.count == actual.count && zip(actual, expected).allSatisfy { jsonContains($0.0, $0.1) }
    }
    if expected is NSNull { return actual is NSNull }
    return String(describing: actual) == String(describing: expected)
}
private func renderJSON(_ value: Any) -> String { guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) else { return String(describing: value) }; return text }
private func normalizeSpaceCharacters(_ value: String) -> String {
    value.replacingOccurrences(of: "\u{00a0}", with: " ").replacingOccurrences(of: "\u{202f}", with: " ")
}
private func exampleLabel(_ example: [String: Any]) -> String {
    [string(example["message"]) ?? string(example["locale"]), string(example["description"])].compactMap { $0 }.joined(separator: " / ")
}
