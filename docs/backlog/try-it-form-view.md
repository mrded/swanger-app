---
worth: yes
where: App/Swanger/TryItView.swift:15
added: 2026-10-28
---
# a form view in Try it, beside JSON

## Why

Try it only has a JSON editor. For a big schema with choices and conditional fields, writing a valid
payload by hand means reading the diagram, typing keys, and fixing typos the validator then reports. A
form built from the schema shows which fields exist, which are required, what values are allowed and
which variant you're in, so people who don't write JSON every day (reviewers, testers, product people)
can build or tweak a payload too.

## How it works today

- `TryItView` (`App/Swanger/TryItView.swift`) shows a bar (Examples menu: the schema's examples named by
  `ExampleNames`, then "Required Fields Only" from `Skeleton.payload(for:in:)`; the outcome label), then a
  `JSONEditor` over an `IssueList` in a `VSplitView`.
- `TryItModel` (`App/Swanger/TryItModel.swift`) owns `text`. Setting it saves the draft
  (`TryItDrafts`, `UserDefaults` keyed by spec path + schema) and checks it 300 ms later off the main
  actor with `PayloadValidator`, giving an `Outcome` (`.valid`, `.invalid([TryItIssue])`, `.syntaxError`).
  Each `TryItIssue` has the `ValidationIssue` (kind, pointer, message), its text range, and `path`: the
  nearest diagram row (`SchemaNode.path(to:in:)`, which steps through the variant the payload most likely
  is, `Sources/SwangerCore/Model/SchemaNode+Lookup.swift`).
- `JSONEditor` has its own `UndoManager` (the window's marked the read-only document as edited).
- `docs/architecture.md` lists "a form view in Try it" under "Not planned for now"; remove it from that
  list when this lands, and describe the form in the app section.

## What to build

A JSON / Form switch in Try it's bar. **The JSON text stays the one source of truth**: the form reads the
parsed text and every change in it is written back as text (`JSONValue.prettyText`), so checking, drafts,
examples and "Required Fields Only" work in both views unchanged.

The form follows the schema model (`SchemaNode`), from the page's schema down:

- **Scalars**: a control by type (`ScalarSchema.types`):
  - string: a text field; a multi-line text area when the value is long or `maxLength` allows much more
    (e.g. over 100);
  - number / integer: a number field that keeps the value as written (`numberLiteral`), so `1.50` isn't
    rewritten to `1.5`;
  - fixed values (`allowedValues`, i.e. `enum` / `const`) and booleans: a picker;
  - a hint under the control from the format, pattern and limits, worded as the rules are (`Wording`);
  - anything the form can't present (the value has the wrong type, several types allowed, any value,
    `unresolved`, `never`): a small raw JSON field for that value. The form never refuses or drops a
    value; it's the validator's job to say it's wrong.
- **Objects**: a collapsible group per object field; each field shows a badge from `Field.presence`
  (Required, Conditional, Optional, Not allowed), the conditional ones with their `decidedBy` rules as
  help. Required fields are shown; optional ones are added on demand from an "Add field" menu. Fields in
  the payload that the schema doesn't have are shown too, marked, so they can be seen and removed.
- **Choices** (`ChoiceSchema`): a picker of the variants. The current variant is the one whose
  discriminator value the payload has, else the best fit (no clash with a fixed value, most fields in
  common), the same idea `SchemaNode.path(to:in:)` and `IssueReader` already use (make that helper
  reachable rather than writing a third copy). Choosing a variant sets its fixed values (`const` fields,
  e.g. `type: "Card"`) and keeps the fields the new variant also has.
- **Arrays**: each item as a group with remove and move up / down; "Add item" adds a new item built like
  the skeleton for the item schema. `prefixItems` are shown by position.
- **New values** (adding a field, an item, switching variant): start from what `Skeleton` would give for
  that node (first allowed value, `default`, or a typed placeholder).
- **Recursive fragments** (`.recursive`): shown collapsed, expanded on demand, so the form doesn't recurse
  forever.
- **Issues**: each issue is shown under its field (by `TryItIssue.path`), or under the nearest field the
  form shows. Choosing an issue in the list scrolls to and focuses that field, as it selects text in JSON
  mode now. The issue list stays below in both modes.
- **When the text isn't JSON**: the form can't show it. Show the syntax error with a button to switch to
  JSON to fix it.

## Design notes

- Writing back reformats the text (`prettyText`), so switching to the form and editing normalises the
  JSON's whitespace. Key order is kept (`OrderedJSON`). That's acceptable; say so in the UI help, or only
  rewrite on an actual form edit.
- Text field edits write back on each change without rebuilding the form (so focus stays); add, remove,
  reorder and variant changes rebuild it.
- Undo should cover form edits too: register them with the editor's `UndoManager`, or keep one undo
  stack on `TryItModel` for both views.
- The form follows the model, which may be *less* strict than the validator (`docs/model-boundaries.md`),
  never stricter. So the form can offer something the validator then rejects (the issue list says so), but
  must never stop a value the validator would accept.
- Big schemas (GitHub's spec): build groups lazily (collapsed groups don't build their children).

## Tests

UI logic worth unit tests, kept out of the view (e.g. in `SwangerValidation` beside `Skeleton`): editing
a value at a path writes the right JSON back; adding / removing / reordering; switching variant sets
fixed values and keeps shared fields; the current variant is picked by discriminator, then best fit;
unknown fields survive a round trip; numbers keep their literal form. A UI smoke test switching to the
form on the existing fixture.

## Open questions

- Whether the chosen view (JSON or form) is remembered globally or per spec. The default when nothing
  was chosen (form or JSON).
