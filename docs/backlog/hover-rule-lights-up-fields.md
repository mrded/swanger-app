---
worth: yes
where: App/Swanger/CardView.swift:75
added: 2026-10-28
---
# hovering a rule lights up the fields it names

## Why

A card lists its rules at the bottom (`CardView.footer`), but nothing ties a rule to the rows it's about.
On a long card you read "When `status` is "Rejected": `reason` is required" and then hunt for both rows.
Hovering a rule should show which rows it talks about.

## What to build

- Hovering a rule in a card's footer highlights every row in that card whose field the rule names.
- From each of those rows, a line runs out of the row's left edge, down outside the card's left edge,
  and into the rule. Each line is a step further out than the one before (by row order), so they don't
  overlap. The link shows even when the row is far above the rule on a tall card.
- Leaving the rule clears it. Nothing is selected and no history entry is made.
- Rows only: a name that isn't a row on this card (a field inside a variant's card, a fragment's name,
  a value) is ignored.
- Use the rule colour (`Color.swangerAmber`) for the lines and highlight, distinct from the selection and
  search highlight `RowView` already has (`isSelected`, `isHighlighted`).
- Optional, same mechanism in reverse: hovering a conditional row highlights the rules in
  `Field.decidedBy`.

## How it works today

- `Rule` (`Sources/SwangerCore/Model/Rule.swift`) is just `kind` + `text`. Field names are in backticks in
  the text, but backticks also hold values (`Wording.literal` wraps arrays and objects), fragment names
  ("it's a `Card`") and keywords ("must match `unevaluatedProperties`"). So parsing backticks would light
  up the wrong things; the rule should carry the names it's about.
- Where rules are made, the names are already known:
  - `SchemaBuilder+Conditions.swift`: `rule(for:present:)` words `if`/`then`/`else`; the `if`'s
    `facts.properties` keys are the fields it tests, and `decidedFields(_:)` returns the fields the
    branches require or forbid. `conditionRules` already returns `(rule, decides)`.
  - `SchemaBuilder+Facts.swift` `dependencies()`: the field and the fields it requires (`(rule, decides)`).
  - `SchemaBuilder.swift` `choiceRules`: the discriminator `property`, and the distinguishing fields of
    each variant.
  - Constraint rules (`constraintRules`) are about the value itself and name no fields.
- `Field.decidedBy` already links a field to the rules that require or forbid it (the reverse direction).
- Rows: `DiagramCard.rows` (`App/Swanger/DiagramCards.swift`); a field row has `kind == .field(Field)` and
  a `path` ending in `.field(name)`. All rows share `DiagramMetrics.rowHeight` and sit under
  `headerHeight`, so `DiagramMetrics.rowMiddle(index)` gives a row's centre within its card.
- The connectors between cards are drawn in a `Canvas` behind the cards from `CardBounds` anchors
  (`App/Swanger/DiagramView.swift`). The rule lines are within one card, so they can be drawn in an
  overlay on the card instead, with the rule's position taken from an anchor on the footer label.

## Changes

1. Give `Rule` the field names it mentions, e.g. `public let fields: [String]` (default `[]`), and fill
   it at the construction sites above. Keep `Equatable` and the existing initialiser for constraint rules.
2. In `CardView`, track the hovered rule (`onHover` on each footer `Label`), pass the matching row
   indexes to `RowView` for a highlight, and draw the lines in an overlay using row indexes and the
   rule's anchor.

## Tests

`SwangerCore` tests that a rule carries the right names: an `if` testing `status` and requiring
`reason` names both; `dependentRequired` names the field and what it requires; a discriminator choice
names the discriminator; a constraint names none; a condition that falls back to its description names
none. Snapshot tests that print rules can stay as they are if `fields` isn't printed.
