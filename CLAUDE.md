# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
make test                          # run package tests (SwangerCore + SwangerValidation)
make test FILTER=SkeletonTests     # run only matching tests
make lint                          # check formatting with swift-format (as CI does)
make format                        # fix formatting in place
make check                         # lint + test + build app (full CI equivalent)
make build                         # build the app (Debug)
make run SPEC=path/to/spec.yaml    # build and open a spec in the app
make real-world                    # download GitHub's spec and run RealWorldSpecTests
make ui-test                       # run UI smoke tests (needs macOS automation mode)
make xcode                         # open App/Swanger.xcodeproj in Xcode
make clean                         # remove build/ and .build/
```

Requires macOS 15 Sequoia+ and Xcode 27.1 (Swift 6 language mode).

## Architecture

The codebase is split into three layers:

**`Sources/SwangerCore/`** — the library that loads and models an OpenAPI spec:
- `Loading/` — `SpecLoader` reads JSON/YAML into `OrderedJSON` preserving field order; `LargeStack` runs loading on a 64 MB thread to avoid stack overflow on deep specs.
- `References/` — `RefResolver` follows `$ref` JSON Pointers within and across files; broken refs become `unresolved` nodes (warnings, never throws).
- `Normalising/` — `OpenAPI30Normaliser` converts OpenAPI 3.0 to JSON Schema 2020-12 at load time (`nullable` → `type: [T, "null"]`, etc.).
- `Model/` — `SchemaBuilder` walks the resolved tree into a `SchemaNode` tree. `Spec` is the top-level entry point. `FragmentIndex` tracks where every fragment is used. `SearchIndex` ranks results. `Rule` carries plain-English wording reused in validation messages.

**`Sources/SwangerValidation/`** — compiles a schema's closure into a single `$defs` document, runs swift-json-schema against a JSON payload, and converts raw issues into typed, readable `ValidationIssue`s. `JSONSourceMap` maps issue pointers to source offsets for editor highlighting.

**`App/Swanger/`** — a thin SwiftUI layer. `SpecStore` (one per window, `@Observable`) owns the `Spec`, selection, back/forward history (`ViewState`s), and reload-on-file-change via `DispatchSource`. `TryItModel` debounces validation (300 ms) off the main actor. `DiagramCards` + `DiagramLayout` + a `Canvas` render the block diagram.

## Key design constraints

- **Model is not a validator.** `SchemaBuilder` builds a diagram model, not a second JSON Schema implementation. The model must never be *stricter* than swift-json-schema, but it's allowed to be *less* strict. `ValidatorAgreementTests` enforces the one-way invariant. See `docs/model-boundaries.md` before changing model behaviour.
- **Roots vs. fragments.** Request/response body schemas are *roots*; `components/schemas` entries they reach are *shared fragments*. Unused components are ignored.
- **OpenAPI 3.0 normalisation happens once at load**, so the model only ever sees JSON Schema 2020-12.
- **`$ref` sibling workaround**: swift-json-schema 0.14 bug — `{$ref: X, additionalProperties: false}` is compiled as `{allOf: [{$ref: X}], additionalProperties: false}`. See `SwangerValidation/PayloadValidator.swift` and `docs/backlog/report-ref-sibling-bug-upstream.md`.
- **No sandboxing**: the app reads spec-referenced files directly. Debug builds have the hardened runtime off so the debugger can attach.

## Testing

- `Tests/SwangerCoreTests/` and `Tests/SwangerValidationTests/` use Swift Testing with hand-written fixtures and snapshots.
- `ValidatorAgreementTests` checks the model is never stricter than the validator.
- `RealWorldSpecTests` requires GitHub's spec: run `scripts/fetch-real-world-specs.sh` first (CI sets `REQUIRE_REAL_WORLD_SPECS` to fail instead of skip).
- Snapshots live under `Tests/SwangerCoreTests/Snapshots/`; update them by running the tests with `RECORD=1` or equivalent.

## Code style

Formatted with `swift-format` and the `.swift-format` config at the repo root. Run `make format` after every code change to Swift files — `swift-format` is strict about indentation and line breaks inside `#if` blocks and similar constructs that are easy to get wrong by hand. CI fails on any formatting error. Use `make lint` to check without modifying.

## App Store release process

The App Store build uses a separate Xcode configuration and bundle ID (`ltd.quux.swanger`) from the standalone GitHub build (`io.github.mrded.swanger`).

**To submit a new version to the App Store:**

```sh
git tag v0.4.0 && git push origin v0.4.0   # tag the release on GitHub as normal
make version                                 # syncs MARKETING_VERSION in Xcode from the tag
```

Then in Xcode:
1. Select the **Swanger AppStore** scheme in the toolbar
2. **Product → Archive** (destination: Any Mac)
3. Organizer opens → **Distribute App → App Store Connect → Upload**
4. Click through the options, confirm bundle ID is `ltd.quux.swanger` → **Upload**

Also increment the **Build** number (`CURRENT_PROJECT_VERSION`) in the target's General tab each time you upload — Apple requires it to be unique per submission even if the version is the same.

**Key differences from the standalone build (`#if APPSTORE`):**
- File watching disabled (`DispatchSource` not set up)
- Specs with external file `$ref`s show "Spec not supported" instead of the diagram
- Sandboxed (`App/Swanger-AppStore.entitlements`): `app-sandbox` + `user-selected.read-only`

## Known issues / deferred work

`docs/backlog/` has one file per known issue. Read the relevant item before touching an area it covers (e.g. `large-recursive-groups-hang-the-model.md`, `model-ignores-some-keywords.md`).
