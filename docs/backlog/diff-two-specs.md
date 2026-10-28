---
worth: yes
added: 2026-10-28
---
# show what changed between two specs

## Why

When an API's schemas change, reviewers need to know what changed, not just what the new version looks
like. A text diff of the YAML is noisy (reordered keys, moved `$ref`s, rewording) and doesn't say what a
change means for a payload: a field newly required, an enum value removed, a limit tightened. Swanger
already turns a spec into fields, rules and limits in plain English; comparing those between two versions
gives a review in the same terms the diagram uses.

## Depends on

`several-versions-in-one-window.md`: both specs loaded in one window, and its `SwangerCore` matching of
roots, fragments and field paths between versions. The comparison is always "base" → "this version".

## What to build

### What's changed page

A page (a sidebar item under Overview, shown only when there is a base) listing, in three sections,
request schemas, response schemas and shared fragments that were **added**, **removed** or **changed**.
Each changed one lists its changed fields:

- the field's path (`lines[].sku`) linking to its row in the diagram (open the cards on the way, select
  and highlight it, as search results do via `DiagramState.show(_:)`);
- the status (added, removed, changed);
- for a change, what changed as before → after pairs, one per aspect ("required: no → yes",
  "allowed values: "Card", "Bank" → "Card"", "max length: 70 → 50").

A field added or removed with everything inside it is listed once, with a count ("added, with 6 fields
inside"), not once per nested field.

### In the diagram

- A **new** or **changed** tag on rows whose field was added or changed (in the row, before the type).
- A dot on a row that has changes somewhere inside it (in the card it opens, or further down), so a
  reviewer can follow the dots to the change without opening everything.
- Removed fields have no row of their own. List them on their parent row: in the inspector when it's
  selected ("Removed inside: `notes`, `legacyId`") and in the dot's tooltip. The parent of `a.b` and
  `a[].b` is `a`; of a variant's field, the variant row.
- Selecting a changed row shows its before → after pairs in the inspector.
- Add the tag and dot to the diagram key (`App/Swanger/DiagramKey.swift`) when the page has changes.

### In the sidebar

A dot on each changed root and fragment, and a **new** tag on added ones. Removed ones only appear on
the What's changed page, since they have no page in this version.

## What counts as a change

A field is changed when anything the diagram or inspector shows for it changed:

- type (`SchemaNode.typeDescription`), including null being allowed (`allowsNull`);
- presence (`Field.presence`: required, conditional, optional, forbidden) and the rules that decide it
  (`Field.decidedBy`);
- the node's own `rules` (constraints, conditions, choices, dependencies);
- allowed values, format, patterns (`ScalarSchema`);
- additional fields allowed or not, pattern fields;
- description, title, deprecated / read-only / write-only;
- the fragment it uses (`Field.fragmentUsed`: name change, or inline ↔ fragment).

Changes *inside* a shared fragment are reported once, under the fragment. A root that uses the fragment
isn't listed as changed for that alone, but its row for the fragment gets the dot, and the fragment's
entry says which roots use it (`FragmentIndex.roots(using:)`), so the reach of a change is visible.

## Design notes

- Compare the two `SchemaNode` trees by walking fields by name (`FieldPath`), not by comparing
  `NodeLocation`s, which differ between files.
- An easy way to keep the diff in step with what's shown is to describe each field as a list of
  `(aspect, text)` pairs ("required" → "yes", "max length" → "70", using the same wording as `Rule.text`
  and `Wording`) and diff those per field. Put the describer in `SwangerCore`; the inspector
  (`App/Swanger/InspectorView.swift`, `FieldDetails`, `ValueSections`) builds its facts in the view today,
  so moving that wording into the core could serve both.
- Variants: match by discriminator value, else by name (`Variant.name`), else by position.
- Recursive fragments (`SchemaNode.Kind.recursive`) stop the walk, as the diagram does.
- A renamed component or moved schema file shows as one removed and one added; that's expected.
- The comparison runs off the main actor like loading does, and again whenever either version reloads.

## Tests

`SwangerCore` tests on pairs of hand-written fixtures, one per kind of change: field added, removed (with
nested fields, counted once), made required, enum value removed, pattern changed, limit changed, rule
reworded, description changed, fragment renamed, variant added, a change inside a shared fragment
reported once and marked on the roots' rows. A spec compared with itself has no changes.

## Open questions

- Which version is the base when more than two are open: the previous one in the list (default), or one
  the viewer picks.
- Whether to also offer the changes as Markdown (copy or export) for pasting into a PR or review.
