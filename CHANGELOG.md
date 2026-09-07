# Changelog

## 0.2.0

- Align datafile validation, format merging and missing versus null conditions with the JavaScript SDK.
- Evaluate ICU branches lazily and correct missing argument, number style and skeleton handling.
- Add generated Unicode CLDR cardinal and ordinal plural rules, parent locales and published sample tests.
- Improve date fields, hour options, time zones and native flexible day periods.
- Strengthen module removal, failed setup cleanup and shared asynchronous shutdown.
- Expand executable conformance fixtures and run strict project examples in CI.
- Document native formatting boundaries and reproducible plural rule generation.

### Upgrade notes

- Corrected formatting can change output. Use native Apple results rather than relying on old formatting bugs.
- Missing arguments in selected ICU branches fail; arguments in unselected branches remain unevaluated.
- Integration CI requires the updated project-1 template from the published Messagevisor CLI.

## 0.1.0

- Initial Messagevisor Swift SDK for Apple platforms.
