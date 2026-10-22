# Swanger

[![CI](https://github.com/mrded/swanger-app/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/mrded/swanger-app/actions/workflows/ci.yml)

**OpenAPI schema viewer for macOS.**

Swanger opens an OpenAPI 3.0 or 3.1 file (JSON or YAML) and shows the resources it defines:

- every request and response body schema as an interactive block diagram,
- the shared fragments (`components/schemas`) they're built from, and where each one is used,
- a **Try it** editor that checks a JSON payload against a schema and explains what's wrong in plain English.

Swanger is **not an API explorer**. There's no endpoint list, no parameters, servers or auth, and it never
sends requests. It reads `paths` only to find which schemas are request and response bodies.

It's a native SwiftUI app for macOS 15 Sequoia and later.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/diagram-dark.png">
  <img alt="A request schema's diagram: the NewOrder card with its customer, lines and payment cards open, and the inspector showing the sku field's pattern" src="docs/screenshots/diagram-light.png">
</picture>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/overview-dark.png">
  <img alt="The overview: a card for each request schema, and a grid of which shared fragments each schema uses" src="docs/screenshots/overview-light.png">
</picture>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/try-it-dark.png">
  <img alt="Try it: a refund payload in the editor, with three issues listed under it: it mustn't have amount, a rejected refund needs a reason, and paymentId must be a UUID" src="docs/screenshots/try-it-light.png">
</picture>

> Searching for "swanger"? Search engines tend to correct it to "swagger". Look for "Swanger OpenAPI schema
> viewer for macOS".

## What the diagram is (and isn't)

The diagram and its plain-English rules show what the spec **says**. Whether a payload is valid is decided
only by Try it's JSON Schema validator. For rare keyword combinations (contradictions,
`unevaluatedProperties`, `not: {type: …}`, …) the diagram can be less strict than the validator, but never
stricter. The exact boundaries are in [Model boundaries](docs/model-boundaries.md). Please read them before
reporting a mismatch or extending the model.

## Status

Early development. Known issues and ideas are in [`docs/backlog/`](docs/backlog), and
[How Swanger works](docs/architecture.md) covers the scope and the code.

## Installing

Swanger needs macOS 15 (Sequoia) or later. Download `Swanger-<version>.dmg` (or `.zip`) from the
[latest release](https://github.com/mrded/swanger-app/releases/latest) and drag `Swanger.app` into
**Applications**.

Releases aren't notarised by Apple yet, so macOS blocks Swanger the first time you open it ("Apple could not
verify…"). Click **Done**, then open **System Settings › Privacy & Security**, scroll down to the message
about Swanger and click **Open Anyway**. You only need to do this once. Or remove the quarantine flag
instead:

```sh
xattr -dr com.apple.quarantine /Applications/Swanger.app
```

## Trying a build from a pull request

Every CI run attaches the app it built. Open the run from the pull request's **Checks** tab (or the
[Actions](https://github.com/mrded/swanger-app/actions/workflows/ci.yml) page), download
`Swanger-<commit>.zip` under **Artifacts**, and unzip it.

These builds are signed ad hoc, not with a Developer ID, so open them the same way as a release (see
[Installing](#installing)).

Artifacts are kept for 14 days.

## Building

You need Xcode 27 or later.

```sh
make test                       # core and validation libraries
make run                        # build the app and open a sample spec (SPEC=path/to/spec.yaml)
make                            # every command
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for more.

## Licence

[MIT](LICENSE).
