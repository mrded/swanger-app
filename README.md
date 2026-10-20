# Swanger

**OpenAPI schema viewer for macOS.**

Swanger opens an OpenAPI 3.0 or 3.1 file (JSON or YAML) and shows the resources it defines:

- every request and response body schema as an interactive block diagram,
- the shared fragments (`components/schemas`) they're built from, and where each one is used,
- a **Try it** editor that checks a JSON payload against a schema and explains what's wrong in plain English.

Swanger is **not an API explorer**. There's no endpoint list, no parameters, servers or auth, and it never
sends requests. It reads `paths` only to find which schemas are request and response bodies.

It's a native SwiftUI app for macOS 15 Sequoia and later. Screenshots will be added once there's something to
show.

> Searching for "swanger"? Search engines tend to correct it to "swagger". Look for "Swanger OpenAPI schema
> viewer for macOS".

## Status

Early development. See [the v1 plan](docs/plans/20261020-swanger-v1.md) for what's coming.

## Building

You need Xcode 27 or later.

```sh
swift test                      # core and validation libraries
open App/Swanger.xcodeproj      # the app; run the Swanger scheme
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for more.

## Licence

[MIT](LICENSE).
