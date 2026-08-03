# Messagevisor Swift SDK <!-- omit in toc -->

Messagevisor's Swift SDK evaluates translations from Messagevisor datafiles in native Apple applications. It follows the same portable runtime contract as the primary JavaScript SDK while using Swift and Foundation APIs that feel natural on Apple platforms.

The package supports iOS 13+, macOS 10.15+, tvOS 13+, watchOS 6+, and visionOS 1+. It includes the core SDK, ICU-style message formatting, simple interpolation, missing-translation observation, and a project conformance CLI.

Visit [https://messagevisor.com](https://messagevisor.com) for more information.

## Table of contents <!-- omit in toc -->

- [Installation](#installation)
- [Public API](#public-api)
- [Initialization](#initialization)
- [Datafile fetching](#datafile-fetching)
- [Recommended modules](#recommended-modules)
- [Translations](#translations)
  - [Translating with values](#translating-with-values)
  - [`t` alias](#t-alias)
  - [Raw translation](#raw-translation)
  - [Arbitrary messages](#arbitrary-messages)
- [Context](#context)
  - [Initial context](#initial-context)
  - [Merge context](#merge-context)
  - [Replace context](#replace-context)
  - [Per-call context](#per-call-context)
- [Datafile operations](#datafile-operations)
  - [Set after initialization](#set-after-initialization)
  - [Merge by default](#merge-by-default)
  - [Replace explicitly](#replace-explicitly)
  - [Loading another locale](#loading-another-locale)
- [Locales, currency, and time zones](#locales-currency-and-time-zones)
  - [Active locale](#active-locale)
  - [Per-call locale](#per-call-locale)
  - [Direction](#direction)
  - [Currency](#currency)
  - [Time zone](#time-zone)
- [Formatting](#formatting)
  - [Direct formatter helpers](#direct-formatter-helpers)
  - [Format precedence](#format-precedence)
- [Defaults](#defaults)
  - [Default translations](#default-translations)
  - [Default formats](#default-formats)
- [Feature and variation resolvers](#feature-and-variation-resolvers)
- [Diagnostics](#diagnostics)
- [Events and snapshots](#events-and-snapshots)
- [Modules](#modules)
  - [Setup API](#setup-api)
  - [Add and remove at runtime](#add-and-remove-at-runtime)
- [Child instances](#child-instances)
- [Translation lookup](#translation-lookup)
- [Closing the SDK](#closing-the-sdk)
- [Apple platform behavior](#apple-platform-behavior)
- [Project conformance CLI](#project-conformance-cli)
- [Development](#development)
  - [Releasing](#releasing)
- [License](#license)

<!-- MESSAGEVISOR_DOCS_BEGIN -->

## Installation

Add the package with Swift Package Manager:

```swift
dependencies: [
    .package(
        url: "https://github.com/messagevisor/messagevisor-swift.git",
        from: "0.1.0"
    )
]
```

Add the products your application needs:

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "Messagevisor", package: "messagevisor-swift"),
        .product(name: "MessagevisorICU", package: "messagevisor-swift"),
    ]
)
```

In Xcode, use **File → Add Package Dependencies** and enter:

```text
https://github.com/messagevisor/messagevisor-swift.git
```

## Public API

The main runtime API is `createMessagevisor()`:

```swift
let m: Messagevisor = createMessagevisor(
    MessagevisorOptions(datafile: datafile)
)
```

Most applications only need `createMessagevisor`, `Messagevisor`, and `MessagevisorOptions`. Public extension and observability types include `MessagevisorModule`, `MessagevisorDiagnostic`, `MessagevisorEvent`, `MessagevisorChild`, and the datafile model types.

The core SDK and module products support the Apple platforms listed above. Shared `Messagevisor` and child state is safe to use from concurrent callers. Module, diagnostic, event, resolver, subscription, and missing translation callbacks are `@Sendable`; callback implementations must synchronize any mutable state they capture.

## Initialization

Create the main runtime with `createMessagevisor()`:

```swift
import Messagevisor

let m: Messagevisor = createMessagevisor(
    MessagevisorOptions(datafile: datafile)
)

print(try m.translate("auth.signin"))
// → "Sign in"
```

The SDK can start without a datafile. This is useful when your application fetches translations after launch:

```swift
let m = createMessagevisor(
    MessagevisorOptions(locale: "en-US")
)

m.setDatafile(downloadedDatafile)
```

## Datafile fetching

The SDK does not prescribe a network layer. Fetch a target- and locale-specific datafile with `URLSession`, load one from your application bundle, or use your existing cache/CDN client.

```swift
import Foundation
import Messagevisor

let url = URL(string: "https://cdn.example.com/messagevisor/ios/en-US.json")!
let (data, _) = try await URLSession.shared.data(from: url)
let datafile = try DatafileContent.fromData(data)

let m = createMessagevisor(
    MessagevisorOptions(datafile: datafile)
)
```

For offline-first applications, bundle an initial datafile and replace or merge fresher content after a successful fetch.

## Recommended modules

Translation lookup and conditional overrides live in the core `Messagevisor` product. Formatting is intentionally modular.

This package includes:

- `MessagevisorICU`: ICU MessageFormat-style interpolation, plural, select, number, date, and time formatting.
- `MessagevisorInterpolation`: lightweight `{name}` replacement for primitive values.
- `MessagevisorMissingTranslations`: observes and optionally deduplicates missing translation diagnostics.

Most applications should choose either ICU or simple interpolation:

```swift
import Messagevisor
import MessagevisorICU

let m = createMessagevisor(
    MessagevisorOptions(
        datafile: datafile,
        modules: [createICUModule()]
    )
)
```

Without a formatting module, `translate()` returns the resolved message string unchanged.

## Translations

Translate a message by key:

```swift
try m.translate("auth.signin")
// → "Sign in"
```

### Translating with values

Pass values when the selected module needs them:

```swift
try m.translate(
    "dashboard.welcome",
    values: ["name": .string("Ada")]
)
// → "Welcome back, Ada"
```

`MessagevisorValue` supports strings, integers, doubles, booleans, dates, arrays, objects, and null:

```swift
let values: MessagevisorValues = [
    "name": .string("Ada"),
    "count": .int(3),
    "price": .double(12.5),
    "enabled": .bool(true),
    "createdAt": .date(Date()),
]
```

### `t` alias

`t()` is an alias for `translate()`:

```swift
try m.t("dashboard.welcome", values: ["name": .string("Ada")])
```

### Raw translation

Use `getRawTranslation()` when you need the selected string before modules format or transform it:

```swift
let raw = try m.getRawTranslation("dashboard.welcome")
```

### Arbitrary messages

Use `formatMessage()` to run a string through the same module pipeline without looking up a message key:

```swift
try m.formatMessage(
    "Hello, {name}",
    values: ["name": .string("Ada")]
)
```

## Context

Context drives message override and segment conditions.

### Initial context

```swift
let m = createMessagevisor(
    MessagevisorOptions(
        datafile: datafile,
        context: [
            "platform": .string("ios"),
            "plan": .string("pro"),
        ]
    )
)
```

### Merge context

`setContext()` shallow-merges by default:

```swift
m.setContext([
    "userId": .string("user-123"),
])
```

Nested objects are replaced at their top-level key; they are not deep-merged.

### Replace context

```swift
m.setContext(
    ["userId": .string("user-456")],
    replace: true
)
```

### Per-call context

Pass request- or screen-specific context without mutating instance state:

```swift
try m.translate(
    "checkout.title",
    options: TranslateOptions(
        context: ["checkoutType": .string("express")]
    )
)
```

Per-call context shallow-merges over instance context for that evaluation only.

## Datafile operations

Messagevisor can hold datafiles for multiple locales and can combine split target datafiles for one locale.

### Set after initialization

```swift
m.setDatafile(datafile)
```

JSON strings are accepted as well:

```swift
m.setDatafile(datafileJSON)
```

Invalid JSON or an invalid datafile emits `invalid_datafile` with the stable message `could not parse datafile`.

### Merge by default

When a datafile already exists for the incoming locale, `setDatafile()` shallow-merges `segments`, `messages`, and `translations`. Incoming identity fields and formats win, while an omitted incoming direction preserves the existing direction.

This supports loading several target datafiles for one locale on demand:

```swift
m.setDatafile(homeDatafile)
m.setDatafile(checkoutDatafile)
```

### Replace explicitly

```swift
m.setDatafile(freshDatafile, replace: true)
```

Replacement removes entries that are absent from the incoming datafile.

### Loading another locale

The first successfully loaded datafile establishes the active locale when no locale was configured. Loading later locales does not silently switch it:

```swift
m.setDatafile(englishDatafile)
m.setDatafile(dutchDatafile)

try m.setLocale("nl-NL")
```

## Locales, currency, and time zones

### Active locale

```swift
try m.setLocale("nl-NL")
print(m.getLocale() ?? "")
```

`setLocale()` requires a loaded datafile for that locale. A locale supplied to `MessagevisorOptions` can still be used with default translations and formats before a datafile arrives.

### Per-call locale

```swift
try m.translate(
    "checkout.title",
    options: TranslateOptions(locale: "fr-FR")
)
```

Per-call locale does not mutate instance state or emit locale events.

### Direction

```swift
let direction = try m.getDirection()
// "ltr" or "rtl"
```

`getDirection()` returns `nil` when no locale is active. Passing a locale explicitly still requires its datafile to be loaded.

### Currency

```swift
m.setCurrency("EUR")
print(m.getCurrency() ?? "")
```

Currency formats without an authored currency use the per-call currency, then the instance currency, then `USD`.

### Time zone

```swift
m.setTimeZone("Europe/Amsterdam")
```

Per-call time zone and currency are available in both `TranslateOptions` and `EvaluationOptions`.

## Formatting

The ICU module supports common authored ICU messages:

```swift
try m.formatMessage(
    "{count, plural, =0 {No items} one {# item} other {# items}}",
    values: ["count": .int(2)]
)
// → "2 items"
```

It supports nested `plural`, `selectordinal`, and `select`, exact plural branches, offsets, apostrophe escaping, simple interpolation, and named number/date/time presets.

Timezone-qualified ISO strings, numeric Unix epoch milliseconds, and native `Date` values can be used for date/time arguments:

```swift
try m.formatMessage(
    "{when, date, long}",
    values: ["when": .date(Date())]
)
```

The Swift string API does not model JavaScript/React rich-message callbacks. With `ignoreTags: true` (the default), tags remain literal text. Requesting rich tag processing emits `unsupported_formatter`.

### Direct formatter helpers

The core SDK exposes Foundation-backed helpers:

```swift
try m.formatNumber(1234.5, preset: "money")
try m.formatDate(Date(), preset: "long")
try m.formatTime(Date(), preset: "short")
try m.formatDateTimeRange(start, end, preset: "appointment")
try m.formatRelativeTime(-1, unit: .day)
try m.formatPlural(2)
try m.formatList(["iOS", "macOS", "visionOS"])
try m.formatDisplayName("NL", type: "region")
```

The `ToParts` methods return a simplified portable representation because Foundation does not expose the same tokenized parts contract as JavaScript `Intl`:

```swift
let parts = try m.formatNumberToParts(1234.5)
// [MessagevisorFormatPart(type: "literal", value: "1,234.5")]
```

Supported display-name types are `language`, `region`, `script`, and `currency`.

### Format precedence

Formats merge in this order:

1. `defaultFormats` supplied to the SDK;
2. formats in the effective locale datafile;
3. per-call `formats`.

The merge extends to individual properties inside named presets.

## Defaults

### Default translations

Defaults allow startup copy or application-owned fallbacks before a datafile is available:

```swift
let m = createMessagevisor(
    MessagevisorOptions(
        locale: "en-US",
        defaultTranslations: [
            "en-US": ["app.loading": "Loading…"]
        ]
    )
)
```

Read the configured defaults for the active locale or another locale:

```swift
let translations = m.getDefaultTranslations()
let dutchTranslations = m.getDefaultTranslations(locale: "nl-NL")
```

You can also pass a call-site fallback:

```swift
try m.translate(
    "optional.copy",
    options: TranslateOptions(defaultTranslation: "Fallback")
)
```

Empty strings are valid explicit translations and do not fall through.

### Default formats

```swift
let formats = FormatPresets(
    number: [
        "money": [
            "style": .string("currency"),
            "minimumFractionDigits": .int(2),
        ]
    ]
)

let m = createMessagevisor(
    MessagevisorOptions(
        locale: "en-US",
        defaultFormats: ["en-US": formats]
    )
)
```

Default formats are shared with child instances and can be inspected without exposing mutable runtime storage:

```swift
let activeFormats = m.getDefaultFormats()
let dutchFormats = child.getDefaultFormats(locale: "nl-NL")
```

## Feature and variation resolvers

Message overrides can reference external feature flags or experiment variations. Messagevisor does not contact a feature service itself; provide resolvers:

```swift
let m = createMessagevisor(
    MessagevisorOptions(
        datafile: datafile,
        resolveFlag: { featureKey, context in
            featureKey == "newCheckout" && context["plan"] == .string("pro")
        },
        resolveVariation: { experimentKey, _ in
            experimentKey == "checkoutCopy" ? "treatment" : nil
        }
    )
)
```

Resolvers can also be installed by modules. Removing that module restores the previous resolver registration.

## Diagnostics

Use `onDiagnostic` for observability:

```swift
let m = createMessagevisor(
    MessagevisorOptions(
        datafile: datafile,
        onDiagnostic: { diagnostic in
            logger.log("\(diagnostic.code): \(diagnostic.message)")
        },
        logLevel: .warn
    )
)
```

Every diagnostic contains `level`, `code`, `message`, and an always-present `details` dictionary. Module provenance and an original Swift error can also be attached.

Stable diagnostic codes include:

- `sdk_initialized`
- `missing_translation`
- `missing_datafile`
- `missing_locale`
- `invalid_datafile`
- `invalid_message`
- `unsupported_formatter`
- `missing_format`
- `invalid_format`
- `message_override_matched`
- `deprecated_message`
- `duplicate_module`
- `module_setup_error`
- `module_close_error`

Without a handler, delivered diagnostics are written to standard error with a `[Messagevisor]` prefix. Change the threshold later with `setLogLevel()`.

Error diagnostics emit the SDK `error` event even when the configured diagnostic threshold filters them from the handler.

## Events and snapshots

Subscribe to a specific event:

```swift
let unsubscribe = m.on(.localeSet) { event in
    if case .localeSet(let locale, let previousLocale) = event.details {
        print("\(previousLocale ?? "none") → \(locale)")
    }
}

unsubscribe()
```

Available events are:

- `change`
- `error`
- `datafile_set`
- `locale_set`
- `context_set`
- `currency_set`
- `timeZone_set`

`subscribe()` is a convenience for change notifications:

```swift
let unsubscribe = m.subscribe {
    render(m.getSnapshot())
}
```

Snapshots include a monotonically increasing version, active locale and direction, context, currency, time zone, loaded locales, and revisions by locale. A `change` event includes the specific source event and its details. Throwing event observers are isolated from state changes and other observers.

## Modules

A module can set up runtime integrations, format or transform translation output, observe/report diagnostics, and clean up resources:

```swift
let uppercase = MessagevisorModule(
    name: "uppercase",
    transform: { payload, _ in
        payload.translation.uppercased()
    }
)

let m = createMessagevisor(
    MessagevisorOptions(
        datafile: datafile,
        modules: [uppercase]
    )
)
```

Return `nil` from `format` or `transform` to preserve the current value.

### Setup API

`setup` receives a `MessagevisorModuleApi` with:

- `setFlagResolver`
- `setVariationResolver`
- `getRevision`
- `onDiagnostic`
- `reportDiagnostic`

```swift
let observer = MessagevisorModule(
    name: "observer",
    setup: { api in
        _ = api.onDiagnostic({ diagnostic in
            print(diagnostic.code)
        }, MessagevisorModuleDiagnosticOptions(logLevel: .warn))
    }
)
```

Duplicate named modules are rejected. Anonymous modules are allowed. Setup failures roll back resolver and diagnostic registrations, report `module_setup_error`, and close partially initialized resources.

### Add and remove at runtime

```swift
let remove = m.addModule(uppercase)
try await remove()
```

The returned removal function is idempotent. You can also remove all modules with a name:

```swift
try await m.removeModule("uppercase")
```

Module ownership belongs to the root instance, not child instances.

## Child instances

Use `spawn()` for request-, task-, or screen-scoped state:

```swift
let child: MessagevisorChild = m.spawn(
    context: ["requestId": .string("request-123")],
    options: SpawnOptions(
        locale: "nl-NL",
        currency: "EUR",
        timeZone: "Europe/Amsterdam"
    )
)

let title = try child.translate("checkout.title")
try await child.close()
```

Children share parent datafiles, modules, resolver registrations, and bounded formatter caches. They isolate context, locale, currency, time zone, snapshots, event versions, and cleanup. Parent datafile and module updates become visible dynamically. A child's `datafile_set` listeners and generic `change` listeners observe parent datafile updates through child-owned events containing the child's active locale, context, snapshots, and monotonically increasing version. Listener unsubscription is local and idempotent. Closing the child removes its single parent bridge without affecting the parent.

`MessagevisorChild` intentionally omits `setDatafile`, `addModule`, `removeModule`, and `spawn`, keeping shared resource ownership unambiguous.

## Translation lookup

For an effective locale and message key, the SDK resolves in this order:

1. The first matching override whose conditions and segments both match.
2. The base datafile translation.
3. `defaultTranslations[locale][messageKey]`.
4. A `missing_datafile` or `missing_translation` diagnostic.
5. Per-call `defaultTranslation`.
6. The message key.

Matching overrides emit `message_override_matched` at debug level. Deprecated messages emit `deprecated_message`. The full instance context is shallow-merged with per-call context before evaluating conditions and segments.

Condition operators are type-strict. Regular expressions use the portable `i`, `m`, `s`, and `u` flags, with `u` mapped to Foundation's Unicode-aware regular expression behavior. Repeated flags, lookarounds, named or non-capturing groups, inline flags, backreferences, and possessive quantifiers are not portable and do not match. Character classes and escaped literal backslashes remain valid. Invalid or non-portable expressions return false for both `matches` and `notMatches`.

## Closing the SDK

Close root instances when their lifecycle ends:

```swift
try await m.close()
```

Closing clears event and diagnostic subscriptions and closes root-owned modules in reverse registration order. Cleanup continues after individual errors; failures emit `module_close_error` and are returned together as `MessagevisorCloseError`.

Repeated or concurrent calls to `close()` await the same cleanup operation. Modules are closed only once, and every caller receives the same aggregate failure when cleanup fails.

Do not use an instance after closing it.

## Apple platform behavior

The SDK uses Foundation localization APIs and does not contain locale-specific output rewrites. Apple Foundation and JavaScript `Intl` can use different CLDR versions and formatter patterns, so punctuation, spacing, compact-number suffixes, localized zone names, and other presentation can differ while both outputs are valid.

Important platform notes:

- Formatter caches are bounded and shared with child instances.
- Public operations are synchronized for safe access from multiple threads. Public callback types are `@Sendable`. Callback implementations must synchronize mutable captured state and should avoid long-running work on the caller's thread.
- Foundation does not expose JavaScript-compatible tokenized formatter parts; `ToParts` methods use a simplified representation.
- Unsupported formatter capabilities are non-fatal and use `unsupported_formatter` where the SDK can identify them.
- Invalid explicit options, such as a malformed currency code or unknown time zone, emit `invalid_format` and throw a `MessagevisorError`.
- Compact notation uses Foundation's locale data. Foundation does not expose separate short and long compact styles, so `compactDisplay: long` emits `unsupported_formatter` and uses the native compact form.
- Rich ICU callback values are a JavaScript/framework feature; Swift translation results are strings.

Use `expectedByRuntime.swift` in shared project fixtures when an exact Apple-native expectation is intentional. Do not hardcode locale-specific rewrites into application or SDK code.

## Project conformance CLI

The package includes `messagevisor-swift`, a development runner that evaluates real Messagevisor project tests through the Swift SDK.

```sh
swift run messagevisor-swift test \
  --projectDirectoryPath=/path/to/messagevisor-project \
  --target=swift \
  --withIcuModule \
  --normalizeSpaces \
  --onlyFailures
```

Useful commands:

```sh
swift run messagevisor-swift evaluate \
  --projectDirectoryPath=/path/to/project \
  --target=swift \
  --locale=en-US \
  --message=auth.signin

swift run messagevisor-swift benchmark \
  --projectDirectoryPath=/path/to/project \
  --target=swift \
  --locale=en-US \
  --message=auth.signin \
  -n 100000

swift run messagevisor-swift examples \
  --projectDirectoryPath=/path/to/project \
  --target=swift \
  --withIcuModule \
  --normalizeSpaces
```

The runner shells out to the project's installed `npx messagevisor` CLI for source loading and datafile generation, then performs evaluations in Swift. Every assertion is compared; the runner never skips native formatting cases. `--normalizeSpaces` treats ordinary spaces, no-break spaces (`U+00A0`), and narrow no-break spaces (`U+202F`) as equivalent, matching the Java runner and keeping fixtures readable. All other Apple Foundation differences must be recorded explicitly with `expectedByRuntime.swift`.

<!-- MESSAGEVISOR_DOCS_END -->

## Development

Run the native package checks:

```sh
swift build
swift test
make strict-concurrency
```

The strict concurrency build compiles every package product in Swift 6 language mode while the published package keeps its Swift 5.9 tools baseline.

Run the full reference project suite:

```sh
make test-project-1
```

This executes the Swift unit/conformance tests and all tests from `messagevisor/messagevisor/projects/project-1`. The package bundles a copy of `conformance/sdk-v1.json` so portable contracts remain executable from an independent checkout.

Verify every public library product from clean consumer packages:

```sh
make verify-consumers
```

### Releasing

1. Update the installation version in this README, `messagevisorSwiftVersion` in the CLI, and the matching version in `CHANGELOG.md`.
2. Merge the release commit into `main`.
3. Tag the release with a semantic version using a `v` prefix, such as `v0.1.0`, and push the tag.
4. GitHub Actions validates the tag, tests the package, builds all public products from clean consumers, and verifies the release configuration.
5. Create the corresponding GitHub release after the tag validation succeeds.

## License

MIT © [Fahad Heylaal](https://fahad19.com)
