# How Swanger works

Notes for working on the code. The layout, build commands, CI and releasing are in
[CONTRIBUTING.md](../CONTRIBUTING.md); what the model deliberately leaves to the validator is in
[Model boundaries](model-boundaries.md).

## Scope

Swanger shows the **resources** an OpenAPI 3.0 or 3.1 file defines, not its endpoints. Paths are read only
to find which schemas are request and response bodies.

- Every request body schema is a _request schema_, every response body schema a _response schema_ (together,
  _roots_); every `components/schemas` entry they reach is a _shared fragment_. Unused components aren't
  shown.
- Input: OpenAPI 3.0.x and 3.1.x, JSON and YAML, `$ref`s within the file and to relative files. Swagger 2.0
  is refused with a clear message.
- Native SwiftUI throughout, no WebKit. macOS 15 Sequoia or later, Swift 6 language mode.
- Distributed outside the App Store and not sandboxed, so files a spec refers to are read directly.

Not planned for now: endpoint views, a form view in Try it, made-up example values, checking a single card on
its own, multiple versions per window, an "unused components" group, exporting a diagram as an image, a Quick
Look extension, a command-line tool sharing `SwangerCore`, spreadsheet export, Swagger 2.0.

## Loading (`SwangerCore`)

- `SpecLoader` reads JSON or YAML (by extension, else by sniffing) into swift-json-schema's `OrderedJSON`,
  so fields keep the order the spec gives them. YAML goes through Yams' `Node` API to keep line and column
  for `LoadError`s.
- `RefResolver` follows JSON Pointers (with `~0`/`~1` unescaping) and relative file refs, loading each file
  once. Each resolved node remembers its origin (component name or `file#pointer`), which names fragments.
  The second visit to a schema on the same path becomes `recursive(origin)`. Broken refs never throw: they
  become `unresolved(ref, reason)` nodes and are collected as warnings.
- 3.0 documents are normalised to JSON Schema 2020-12 once at load: `nullable` → `type: [T, "null"]` (and
  `null` added to an `enum`), boolean `exclusiveMinimum`/`exclusiveMaximum` → numeric, `example` →
  `examples`.
- Loading and Try it's checks run on `LargeStack`: a thread with a 64 MB stack. GitHub's schemas nest deep
  enough to overflow the 512 KB stack of a `Task.detached` thread in debug builds.

## The model

- Roots come from `paths.*.*.requestBody.content.*.schema` and `responses.*.content.*.schema`, preferring
  `application/json`, else the first JSON-like media type. A root is named after its component when the
  body is a `$ref`, otherwise `<operationId> request` / `<operationId> <status> response`, falling back to
  `<METHOD> <path>`. A component used by several operations is one root.
- A choice's discriminator is a property that is a `const` or single-value `enum` in every variant.
- Keywords beside a `$ref` tighten the fragment in place (forbidden fields, newly required fields, extra
  constraints); when they add fields of their own it's a new object.
- `Rule` wording is plain English, reused by validation messages (`Wording`).
- `FragmentIndex` records every root and path where a fragment appears, direct or nested (`via`).
- `Spec.resolvedSchemas` keeps every schema the roots and fragments reach, including ones linked from
  keywords the model doesn't show (`propertyNames`, …), so the validator sees them.
- `FieldPath` (with `.prefixItem(Int)`) and `SchemaNode.node(at:)`/`field(at:)` follow a path back to its
  node. `SchemaNode.path(to:in:)` turns an issue's pointer into the nearest diagram row, going through the
  variant whose discriminator value the payload has.
- `SearchIndex` ranks exact, prefix, word start, then contains. A field matches on its own name, never on
  the fields it sits inside; a dotted query (`address.postcode`) matches the end of a path.

## Validation (`SwangerValidation`)

- `PayloadValidator` writes the closure of one schema into `$defs` of a single document, with `$ref`s
  rewritten to point there, and caches the compiled validator. An unresolved `$ref` is dropped, so it allows
  anything, as the diagram shows it unresolved.
- swift-json-schema 0.14 bug: `additionalProperties` and `items` see the `properties` and `prefixItems` of a
  `$ref` beside them, so `{$ref: X, additionalProperties: false}` accepts fields it should reject. Worked
  around by compiling `{$ref: X, ...}` as `{allOf: [{$ref: X}], ...}`, which 2020-12 treats the same. Not
  reported upstream yet (`docs/backlog/report-ref-sibling-bug-upstream.md`).
- `format` is asserted for the library's built-in formats (`date-time`, `date`, `time`, `email`,
  `hostname`, `ipv4`, `ipv6`, `uuid`, `uri`, `uri-reference`); others are ignored.
- Issues are typed by keyword (*Missing*, *Wrong type*, *Not allowed value*, *Wrong format*, *Out of
  range*, *Unexpected field*, *Rule not met*) and worded from the failing keyword's value, not the
  library's message. Condition branches use the schema's `description`; composition summaries explained by
  issues below them are dropped; wrong type is reported once. An array item past the last allowed one
  (`items: false`) is an *Unexpected field*.
- A failed `oneOf`/`anyOf` reports the variant the payload was most likely meant to be: the one whose fixed
  values and type it has, else the one with fewest issues. When none fits, it reports what the
  discriminator or type would need to be, and "Needs `email` or `phone`" when the variants only miss
  fields.
- Skeletons have required fields only, with the first allowed value or a typed placeholder, and one item in
  an array whose items are objects or choices.
- Examples are named by what sets them apart ("type: Card", "with reason"): differing fixed values, then
  which optional fields are present, then one level down, then the shortest differing value. They're
  printed by `JSONValue.prettyText` (`"key": value`), not the library's pretty-printer.
- `JSONSourceMap` maps pointers to UTF-16 ranges: a member selects its key and value; a missing one climbs
  to the nearest key or opening bracket. It also converts the parser's line and byte column to an offset and
  matches brackets outside strings.

## The app

- `DocumentGroup(viewing:)` with a read-only document for JSON and YAML. An `@Observable` `SpecStore` per
  window loads on a background task and holds the `Spec`, warnings, selection and history. `DispatchSource`
  watches the spec and every file it referenced; a debounced reload keeps the selection, and a failed
  reload keeps the old model under an error banner.
- `SpecStore.history` is the window's back/forward list of `ViewState`s: the page, the open rows, the card
  shown on its own, the selected row and the viewport. Opening or closing a card, showing a card on its own,
  changing page and choosing a search result are moves; selecting a row that opens nothing only changes the
  current entry, so going back isn't a click-by-click replay. Swipe is the three-finger (`NSEvent.swipe`)
  gesture; two-finger page swipes aren't caught.
- `DiagramCards` turns a schema and its open rows into cards, parents first; `DiagramLayout` places them
  left to right and a `Canvas` draws the connectors. Rows all share one height (`DiagramMetrics`) so
  connectors can find them. A row holding an array of objects opens the item's card directly (`lines[]`);
  an array card is only shown for `prefixItems`.
- AppKit throws "more Update Constraints in Window passes than there are views" on macOS 27 when the
  window's minimum width is less than the split view's columns need. So the window sets no `minWidth` of its
  own (the sidebar, detail and inspector minimums decide it), and the diagram draws its cards in an overlay
  so their size never becomes its minimum.
- `SpecStore.mode` (`DetailMode`) switches a schema page between the diagram and Try it (⌥⌘D, ⌥⌘T). It isn't
  in the history and stays as it is from page to page; leaving the diagram saves its viewport into the
  current entry. Choosing an issue selects its row without a history entry (`SpecStore.revealOnThisPage`).
- `TryItModel` checks the text 300 ms after typing stops, off the main actor, and saves it as the draft
  then. Drafts are one `UserDefaults` dictionary (`tryItDrafts`) keyed by the spec's path, the direction
  and the schema's file and pointer. A page starts from its draft, else its first example, else its
  skeleton ("Required Fields Only" in the menu).
- The editor has its own `UndoManager`: with the window's, typing marked the read-only document as edited,
  and macOS restored that "Edited" mark on the next launch.
- The About window is a SwiftUI `Window` scene replacing the standard About item.

## Testing

- `swift test` covers the core and validation with Swift Testing, hand-written fixtures and snapshots.
- `ValidatorAgreementTests` checks the model is never stricter than the validator, using `PayloadValidator`.
- `RealWorldSpecTests` loads the Petstores (fixtures, Apache 2.0) and GitHub's REST API spec (downloaded by
  `scripts/fetch-real-world-specs.sh` at a pinned commit and checksum), then checks a skeleton against every
  root. GitHub's takes about 8 s unoptimised. Petstore 3.1 still has two warnings, for `$ref`s to an `$id`
  and an `$anchor` (`docs/backlog/refs-to-id-and-anchor.md`). Stripe's spec is left out because the model
  doesn't finish building it (`docs/backlog/large-recursive-groups-hang-the-model.md`).
- The UI smoke test opens its fixture by passing the path with `-NSTreatUnknownArgumentsAsOpen YES`, and
  chooses the first example from the menu, since its own earlier run leaves a draft. It doesn't mask
  `tryItDrafts` with a launch argument: the app would then save over the real drafts. The app has no
  test-only hooks.
