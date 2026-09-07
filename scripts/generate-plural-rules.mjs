// Regenerate: node scripts/generate-plural-rules.mjs
// Verify without writing: node scripts/generate-plural-rules.mjs --check
// Node.js 24 and network access are needed only for these maintenance commands.
import { readFile, writeFile, mkdir } from "node:fs/promises";

const args = process.argv.slice(2);
if (args.length > 1 || (args.length === 1 && args[0] !== "--check")) {
    console.error("Usage: node scripts/generate-plural-rules.mjs [--check]");
    process.exit(2);
}
const check = args[0] === "--check";
// Resolve from the script, not the caller's working directory.
const repository = new URL("../", import.meta.url);
const version = "48.2.0";
const root = `https://raw.githubusercontent.com/unicode-org/cldr-json/${version}`;
const [cardinal, ordinal, parents, licence] = await Promise.all([
    ...["plurals", "ordinals", "parentLocales"].map(async (name) => {
        const response = await fetch(
            `${root}/cldr-json/cldr-core/supplemental/${name}.json`,
        );
        if (!response.ok) throw new Error(`${name}: ${response.status}`);
        return response.json();
    }),
    fetch(`${root}/LICENSE`).then(async (response) => {
        if (!response.ok) throw new Error(`LICENSE: ${response.status}`);
        return response.text();
    }),
]);

function relation(text) {
    const match = /^([nivwftec])(?: % (\d+))? (!=|=) ([\d.,]+)$/.exec(
        text.trim(),
    );
    if (!match) throw new Error(`Unsupported CLDR relation: ${text}`);
    const [, operand, modulus, operator, ranges] = match;
    const value = modulus
        ? `o.${operand}.truncatingRemainder(dividingBy: ${modulus})`
        : `o.${operand}`;
    const expression = ranges
        .split(",")
        .map((range) => {
            const [low, high] = range.split("..");
            return high
                ? `(${value} >= ${low} && ${value} <= ${high})`
                : `${value} == ${low}`;
        })
        .join(" || ");
    // CLDR '=' is an integer membership test, even for a range with fractional bounds.
    const membership = `(${value}.rounded(.towardZero) == ${value} && (${expression}))`;
    return operator === "!=" ? `!${membership}` : membership;
}
function rule(text) {
    return text
        .split(" or ")
        .map((part) => part.split(" and ").map(relation).join(" && "))
        .map((part) => `(${part})`)
        .join(" || ");
}
let swift = `// Generated from Unicode CLDR ${version}. Do not edit manually.\n// Regenerate: node scripts/generate-plural-rules.mjs\n// Verify: node scripts/generate-plural-rules.mjs --check\n// Licence: UNICODE-LICENSE.txt\n\nenum CLDRPluralRules {\n`;
swift +=
    "    static let parents: [String: String] = [\n" +
    Object.entries(parents.supplemental.parentLocales.parentLocale)
        .map(
            ([locale, parent]) =>
                `        ${JSON.stringify(locale)}: ${JSON.stringify(parent)}`,
        )
        .join(",\n") +
    "\n    ]\n";
for (const [kind, data] of [
    ["cardinal", cardinal],
    ["ordinal", ordinal],
]) {
    const groups = new Map();
    for (const [locale, rules] of Object.entries(
        data.supplemental[`plurals-type-${kind}`],
    )) {
        const body = Object.entries(rules)
            .filter(([key]) => !key.endsWith("-other"))
            .map(([key, value]) => {
                return `            if ${rule(value.split("@")[0].trim())} { return "${key.replace("pluralRule-count-", "")}" }`;
            })
            .join("\n");
        if (!groups.has(body)) groups.set(body, []);
        groups.get(body).push(locale);
    }
    swift += `    static func ${kind}(_ locale: String, _ o: PluralOperands) -> String? {\n        switch locale {\n`;
    for (const [body, locales] of groups) {
        swift += `        case ${locales.map(JSON.stringify).join(", ")}:\n${body ? `${body}\n` : ""}            return "other"\n`;
    }
    swift += `        default: return nil\n        }\n    }\n`;
}
swift += "}\n";
let samples =
    "// Generated from Unicode CLDR " +
    version +
    '. See UNICODE-LICENSE.txt.\nimport XCTest\n@testable import Messagevisor\n\nfinal class CLDRPluralSamplesTests: XCTestCase {\n    func testPublishedCardinalAndOrdinalSamples() throws {\n        for row in Self.samples.split(separator: "\\n") {\n            let fields = row.split(separator: "|")\n            let locale = String(fields[0]), ordinal = fields[1] == "ordinal", category = String(fields[2])\n            for sample in fields[3].split(separator: ",") {\n                let text = String(sample), value = try XCTUnwrap(Double(text))\n                XCTAssertEqual(pluralCategory(PluralOperands(text), locale: locale, ordinal: ordinal), category, String(row))\n                let digits = text.split(separator: ".").dropFirst().first?.count ?? 0\n                XCTAssertEqual(try messagevisorPluralCategory(value, locale: locale, ordinal: ordinal, options: ["minimumFractionDigits": .int(digits), "maximumFractionDigits": .int(digits)]), category, String(row))\n            }\n        }\n    }\n    static let samples = """\n';
for (const [kind, data] of [
    ["cardinal", cardinal],
    ["ordinal", ordinal],
]) {
    for (const [locale, rules] of Object.entries(
        data.supplemental[`plurals-type-${kind}`],
    )) {
        for (const [category, rule] of Object.entries(rules)) {
            const values = [
                ...new Set(
                    rule
                        .split(/@(?:integer|decimal)/)
                        .slice(1)
                        .flatMap((part) => part.split(/[,~]/))
                        .map((value) => value.trim())
                        .filter((value) => /^\d+(?:\.\d+)?$/.test(value)),
                ),
            ];
            if (values.length)
                samples += `${locale}|${kind}|${category.replace("pluralRule-count-", "")}|${values.join(",")}\n`;
        }
    }
}
samples += '\"\"\"\n}\n';
let stale = false;
for (const [path, content] of [
    ["Sources/Messagevisor/CLDRPluralRules.swift", swift],
    ["UNICODE-LICENSE.txt", licence],
    ["Tests/MessagevisorTests/CLDRPluralSamplesTests.swift", samples],
]) {
    const expected = content.replace(/\r\n/g, "\n").trimEnd() + "\n";
    const destination = new URL(path, repository);
    let existing;
    try {
        existing = await readFile(destination, "utf8");
    } catch (error) {
        if (error.code !== "ENOENT") throw error;
    }
    if (existing === expected) {
        console.log(`Current: ${path}`);
    } else if (check) {
        stale = true;
        console.error(
            `${existing === undefined ? "Missing" : "Stale"}: ${path}`,
        );
    } else {
        await mkdir(new URL(".", destination), { recursive: true });
        await writeFile(destination, expected, "utf8");
        console.log(`Generated: ${path}`);
    }
}
if (stale) {
    console.error("Run node scripts/generate-plural-rules.mjs to regenerate.");
    process.exitCode = 1;
}
