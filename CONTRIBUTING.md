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
- Xcode 27.1 (Swift 6 language mode), the version CI uses

## Building and testing

The `Makefile` wraps the usual commands; `make` lists them.

```sh
make check                      # lint, test and build the app, as CI does
make test FILTER=SkeletonTests  # only the matching tests
make real-world                 # also load GitHub's 13 MB spec, as CI does
make ui-test                    # the app's UI smoke tests
make run SPEC=path/to/spec.yaml # build the app and open a spec with it
make release                    # a Release build, signed ad hoc, at build/Swanger.zip
```

Or open `App/Swanger.xcodeproj` in Xcode (`make xcode`) and run the **Swanger** scheme.

`RealWorldSpecTests` loads the Swagger Petstores (kept in `Tests/SwangerCoreTests/Fixtures/real-world/`)
and GitHub's REST API spec, which `scripts/fetch-real-world-specs.sh` downloads at a pinned commit
into `.build/real-world-specs/`. Without it, that one test is skipped locally. CI sets
`REQUIRE_REAL_WORLD_SPECS`, so there it fails instead.

The UI smoke tests (`App/SwangerUITests`) drive the app, so macOS has to allow automation first. Either
approve the prompt the first time they run, or enable it once with
`sudo automationmodetool enable-automationmode-without-authentication`. While they run, leave the
mouse and keyboard alone.

The app is signed to run locally (ad hoc) and isn't sandboxed, so it can read files a spec refers to next to
it. Debug builds have the hardened runtime switched off by Xcode so the debugger can attach; Release builds
have it on.

## Code style

Code is formatted with `swift-format` (it ships with Xcode) using the `.swift-format` file at the repo root.
Before opening a pull request:

```sh
make format                     # xcrun swift-format format --in-place …
make lint                       # xcrun swift-format lint --strict …, as CI runs it
```

## Continuous integration

`.github/workflows/ci.yml` runs on every pull request and every push to `main`:

- **test**: `swift-format lint --strict`, downloads GitHub's spec for `RealWorldSpecTests`, then
  `swift test --parallel`.
- **build**: builds the app scheme for testing and runs its UI smoke tests, then makes
  an ad hoc signed Release build and attaches it to the run as `Swanger-<short sha>.zip` for 14 days.

When a job fails, its test results (`.xcresult` bundles, or xUnit XML from `swift test`) are attached too. A
new push to a pull request cancels the run for the previous push.

CI runs on GitHub's `xcode-27` macOS runner image (a public preview) with Xcode 27.1 selected through
`xcode-select`. When moving to a new Xcode, change `XCODE_APP` in both workflows and the version under
**Requirements** above together. The image's
[readme](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md) lists the
Xcode versions it has.

Workflows are checked with [actionlint](https://github.com/rhysd/actionlint) (configured in
`.github/actionlint.yaml`).

`main` is protected: pull requests need the **test** and **build** checks to pass before they can be merged.

## Releasing

`.github/workflows/release.yml` runs when a tag starting with `v` is pushed. It runs the CI jobs, archives a
Release build with the version taken from the tag, makes `Swanger-<version>.zip` and `Swanger-<version>.dmg`
with a `SHA256SUMS.txt`, and creates a GitHub Release with generated notes. To cut a release:

```sh
git switch main && git pull
git tag v0.1.0
git push origin v0.1.0
```

A tag with a suffix, such as `v0.2.0-beta.1`, is always published as a pre-release.

### Secrets

Set these under **Settings › Secrets and variables › Actions**. Each group is optional: when one is missing,
its steps are skipped and the build is published without it.

| Secret | What it is |
|---|---|
| `DEVELOPER_ID_P12` | The **Developer ID Application** certificate and private key, exported from Keychain Access as a `.p12` and base64 encoded: `base64 -i DeveloperID.p12 \| pbcopy` |
| `DEVELOPER_ID_P12_PASSWORD` | The password chosen when exporting the `.p12` |
| `ASC_KEY_ID` | Key ID of an App Store Connect API key (**Users and Access › Integrations › Team Keys**), with the Developer role |
| `ASC_ISSUER_ID` | The issuer ID shown above that list of keys |
| `ASC_KEY_P8` | The contents of the downloaded `AuthKey_<key id>.p8` file |
| `TAP_TOKEN` | A fine-grained personal access token for `mrded/homebrew-tap` only, with **Contents: read and write** |

What gets published depends on which are set:

| Secrets set | Result |
|---|---|
| None | Ad hoc signed build; the release notes explain how to open it past Gatekeeper |
| `DEVELOPER_ID_*` | Signed with Developer ID but not notarised; the same notes |
| `DEVELOPER_ID_*` and `ASC_*` | Signed, notarised and stapled; opens without a warning |
| All of them | As above, and `Casks/swanger.rb` in the tap is updated to the new version and checksum |

The cask is only updated for notarised releases without a suffix, so `brew install --cask mrded/tap/swanger` always installs a
notarised build.

The certificate is imported into a temporary keychain that is deleted when the job ends.

## Dependencies

Swanger keeps dependencies few and permissively licensed:

- [Yams](https://github.com/jpsim/Yams) for YAML
- [swift-json-schema](https://github.com/ajevans99/swift-json-schema) (the `JSONSchema` product) for JSON
  Schema 2020-12 validation and its order-preserving `OrderedJSON` tree
- [swift-collections](https://github.com/apple/swift-collections) (Apache 2.0, the `OrderedCollections`
  product) for building `OrderedJSON` objects; swift-json-schema depends on it already

Please open an issue before adding a new one.

## Further reading

- [How Swanger works](docs/architecture.md): scope and notes on each part of the code
- [Model boundaries](docs/model-boundaries.md): what the diagram deliberately leaves to the validator
- [`docs/backlog/`](docs/backlog): known issues and deferred work, one file per item
