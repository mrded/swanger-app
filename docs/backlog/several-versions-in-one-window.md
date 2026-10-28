---
worth: yes
where: App/Swanger/SpecStore.swift:9
added: 2026-10-28
---
# open several versions of a spec in one window

## Why

An API often has more than one version of its spec at once: `v1.yaml` and `v2.yaml`, `beta-1` and
`beta-2`, or a file and its copy from another branch. Today each opens in its own window, so comparing
the same schema across them means arranging windows side by side and finding the schema in each. Letting
one window hold several versions, and switch between them while staying on the same schema, makes that a
single click. It's also what `diff-two-specs.md` needs: both specs loaded together, and roots and
fragments matched between them.

## How it works today

- `SwangerApp` uses `DocumentGroup(viewing: SpecDocument.self)`; each document gets a `SpecWindow(url:)`,
  which owns one `SpecStore` (`App/Swanger/SpecStore.swift`).
- `SpecStore` holds a single `spec`, its `searchIndex` and `validator`, the window's `history`
  (`History` of `ViewState`s, `App/Swanger/Navigation.swift`), and a `FileWatcher` over the spec and
  every file it referenced. `reload()` loads off the main actor, keeps the old model on failure, and calls
  `history.prune { spec.contains($0) }` to drop entries for pages that no longer exist.
- Pages are `Page.overview`, `.root(RootID)` and `.fragment(NodeLocation)`. Both IDs contain a full file
  URL: `RootID` is a direction plus the body schema's `NodeLocation` (`Sources/SwangerCore/Model/Spec.swift:80`),
  and a fragment's ID is its `NodeLocation` (file URL + JSON pointer). So a page in one spec never equals
  the "same" page in another file, and every `ViewState` in the history is tied to one spec's files.
- Try it drafts (`App/Swanger/TryItDrafts.swift`) are keyed by the spec's path and the schema's file and
  pointer, so each version keeps its own drafts with no change.
- `docs/architecture.md` lists "multiple versions per window" under "Not planned for now"; remove it from
  that list when this lands, and describe the feature in the app section.

## What to build

- A window holds an ordered list of versions, each a spec file. The one the window opened with is the
  first. Versions are sorted with numeric awareness (`beta-10` after `beta-9`) or kept in the order added
  (see open questions); the last is treated as the latest.
- A version switcher in the sidebar (above the sections) or the toolbar shows each version by its
  `info.version`, falling back to the file name, and switches the window to it.
- Switching keeps the place: the same root or fragment on the other version if it has one, with the same
  mode (diagram or Try it), the same open rows and selection where those paths exist there. If the page
  doesn't exist in the other version, go to that version's overview. A switch is a history move, so Back
  returns to the previous version as it was left.
- Each version loads, reloads on file change and reports errors on its own, as `SpecStore` does now for
  one spec. A version that fails to load shows its error when chosen; the others keep working.
- Removing a version from the window; closing the window closes them all.

### Matching pages across versions

This is the core of the ticket, and `diff-two-specs.md` reuses it, so put it in `SwangerCore` with tests
rather than in the app. Because IDs contain file URLs, match on what stays the same between files:

- A **root**: the same direction and the same pointer relative to its spec (e.g.
  `#/components/schemas/NewOrder`), else the same `RootSchema.name` (component name, or
  `<operationId> request` / `<operationId> <status> response`), else the same operation
  (`RootSchema.operations`: method + path + status).
- A **fragment**: the same pointer, with its file path made relative to the spec's folder, else the same
  `FragmentRef.name`.
- A **field path** (`FieldPath`) is already name-based and carries over as is; drop the parts that don't
  resolve with `SchemaNode.node(at:)` on the other side.

A renamed component doesn't match; that's fine (the diff shows it as one removed and one added).

## Design notes

- Split `SpecStore` into a per-version loader (url, spec, searchIndex, validator, loadError, watcher) and a
  window store (versions, current version, history, mode, search text). Most views read `store.spec`
  today; keep that as "the current version's spec" so they don't all change.
- `History` entries must say which version they're on (`ViewState` gains a version), and `prune` after a
  reload must only drop entries for the version that reloaded.
- Each version is a file read outside the document system. In the App Store build (`#if APPSTORE`,
  sandboxed with `user-selected.read-only`), a file chosen in an open panel can be read for the session;
  keeping it across launches needs a security-scoped bookmark. External `$ref`s stay unsupported there.
- Window restoration: `DocumentGroup` restores the document it opened, not the extra versions. Decide
  whether they're remembered (bookmarks in `UserDefaults`, keyed by the main file) or the window reopens
  with one version.

## Tests

- `SwangerCore`: matching roots and fragments between two fixture specs: same pointer, renamed component,
  root that only matches by operation, root only in one version, fragment in a sibling file.
- The `History` changes: switching version is a move; Back returns to the previous version and page; a
  reload of one version prunes only its entries.

## Open questions

- How a version is added: "Add Version…" (⌘⇧O, an open panel), dropping a file on the window, or offering
  sibling files that look like versions (`*-v2.yaml`, `beta-*` folders).
- Order: by `info.version` / file name, or as added.
- Whether extra versions are remembered across launches.
