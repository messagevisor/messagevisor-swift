# Messagevisor Swift SDK

This repository is the native Swift port of Messagevisor for Apple platforms.

Before runtime work, read `../PORT.md`. The behavioral source of truth is `../messagevisor/packages/sdk`; the real cross-SDK fixture project is `../messagevisor/projects/project-1`.

Key rules:

- Preserve portable JavaScript SDK semantics while using idiomatic Swift and Foundation APIs.
- Never add locale-specific output rewrites merely to match JavaScript `Intl`. Record meaningful Apple output differences explicitly with `expectedByRuntime.swift`; the project runner must evaluate every formatting assertion. `--normalizeSpaces` may equate only ordinary, no-break, and narrow no-break spaces.
- Keep `MessagevisorChild` free of root-owned datafile/module mutation APIs.
- Preserve `could not parse datafile` for invalid datafile diagnostics.
- Keep the bundled `Tests/MessagevisorTests/Resources/conformance/sdk-v1.json` synchronized with the monorepo fixture.
- The SDK README is the source of truth for future extracted website documentation.

Verification:

```sh
swift build
swift test
make test-project-1
```
