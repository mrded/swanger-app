---
worth: yes
where: App/Swanger/CardView.swift:163
added: 2026-10-23
---
# the diagram doesn't show a field's status or a link's kind, and has no key

Show these eight things in the diagram, with a key that explains them:

- Required field
- Conditional: depends on a rule
- Optional field
- Not allowed in this request
- Leads to a required part
- Leads to an optional part
- Leads to a conditional part
- A decision: one variant applies

Today only required (teal dot, bold name) and not allowed (strikethrough) are shown. Optional has no
marker, and every connector looks the same apart from its colour. Conditional isn't in the model at
all: `Field` has only `isRequired` and `isForbidden`. Conditions do know which fields they require (the
`then`/`else` `required` lists in `SchemaBuilder+Conditions.swift`, and `dependentRequired` in
`SchemaBuilder+Facts.swift`), but that only becomes rule text in the card footer.

Proposed design: two separate signals, and none of it shown by colour alone.

- **Row marker for the field's status** (the existing 8pt column in `RowView.marker`): ● filled teal for
  required (name bold), ◐ half-filled for conditional (the tooltip names the rule), ○ hollow grey for
  optional, ⊘ `nosign` for not allowed (name struck through and dimmed).
- **Connector for the link** (`Connectors` in `DiagramView.swift`): the line pattern comes from the row
  the line starts at (solid for required, long dashes for conditional, short dots for optional). The start
  cap uses the same marker as the row. Colour keeps its current meaning, which is what the line points to.
  A ◆ amber diamond at the card edge, once for each choice group, marks a decision.
- **Legend**: a small key that can collapse, at the bottom-left of the diagram (the zoom controls are at
  the bottom-right). It draws the same marker and line views as the diagram, so it can't drift from it.

Work: replace `Field.isRequired`/`isForbidden` with
`enum Requirement { case required, conditional(Rule), optional, forbidden }`, and set it from the
condition and dependency facts that are already parsed (with tests in the style of the condition tests).
Then add a shared `RequirementMarker` view, styled connectors and a `DiagramLegend` view.
Still to decide: whether conditional is amber (amber already means "anything that decides" in
`Theme.swift`, but that's also the colour of decisions) or teal, with only its shape setting it apart.

Related: `card-row-details-cut-short.md` also changes `RowView`.
