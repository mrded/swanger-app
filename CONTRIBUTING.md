# Contributing to Swanger

Thanks for your interest. Issues and pull requests are welcome.

## Layout

| Path | What's there |
|---|---|
| `Package.swift` | SwiftPM package with the `SwangerCore` and `SwangerValidation` libraries and their tests |
| `Sources/SwangerCore/` | Loading specs, `$ref` resolution, OpenAPI 3.0 → JSON Schema 2020-12, the model, rule wording |
| `Sources/SwangerValidation/` | Compiling schemas, validating payloads, readable errors |
| `Tests/` | Swift Testing suites, with hand-written fixtures and snapshots |
| `App/Swanger.xcodeproj` | The macOS app, depending on the local package |
| `App/Swanger/` | SwiftUI views, document type, assets |

Most of the logic lives in the package, so it can be tested with `swift test` alone. The app target should
stay a thin SwiftUI layer on top.

## Requirements

- macOS 15 Sequoia or later
- Xcode 27 or later (Swift 6 language mode)

## Building and testing

```sh
swift test --parallel
xcodebuild -project App/Swanger.xcodeproj -scheme Swanger build
```

Or open `App/Swanger.xcodeproj` in Xcode and run the **Swanger** scheme.

The app is signed to run locally (ad hoc) and isn't sandboxed, so it can read files a spec refers to next to
it. Debug builds have the hardened runtime switched off by Xcode so the debugger can attach; Release builds
have it on.

## Code style

Code is formatted with `swift-format` (it ships with Xcode) using the `.swift-format` file at the repo root.
Before opening a pull request:

```sh
xcrun swift-format format --in-place --recursive Sources Tests App/Swanger
xcrun swift-format lint --strict --recursive Sources Tests App/Swanger
```

## Dependencies

Swanger keeps dependencies few and MIT-licensed:

- [Yams](https://github.com/jpsim/Yams) for YAML
- [swift-json-schema](https://github.com/ajevans99/swift-json-schema) (the `JSONSchema` product) for JSON
  Schema 2020-12 validation and its order-preserving `OrderedJSON` tree

Please open an issue before adding a new one.
