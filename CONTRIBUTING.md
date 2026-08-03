# Contributing

Thanks for helping improve Messagevisor Swift. Please open an issue before a large API or portability change so its relationship with the JavaScript source of truth can be agreed first. By participating, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md). Report vulnerabilities through [SECURITY.md](SECURITY.md), not a public issue.

Read the workspace's `messagevisor/PORT.md` before changing portable runtime behavior. Use Foundation localization APIs and keep formatting generic. Locale-specific labels, fixture-specific output rewrites, and silent skipping do not belong in the SDK.

Before opening a change, run:

```sh
swift build
swift test
make test-project-1
```

Use `expectedByRuntime.swift` for deliberate Apple-vs-JavaScript expectations. The project runner compares every evaluation and has no formatter-skipping mode. Its reference Make targets normalize only ordinary, no-break, and narrow no-break spaces so space-only differences do not make fixtures noisy.
