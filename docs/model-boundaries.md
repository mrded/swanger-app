# Model boundaries

The model (`SchemaBuilder` → `SchemaNode`) exists to draw the diagram and word the rules. It is deliberately
**not** a second JSON Schema implementation. Whether a payload is valid is decided by swift-json-schema in
Try it, never by the model. This keeps the builder reviewable and stops each review from turning up another
rare combination of keywords.

**The model must:**

- never be **stricter** than the validator: anything the validator accepts, the diagram must allow.
  `ValidatorAgreementTests` enforces this, and it's the only correctness bar for keyword combinations. It
  doesn't check that the model is as strict, by design.
- get the common OpenAPI shapes right: objects, arrays, scalars, `$ref` with siblings, `allOf` composition
  (including a closed `additionalProperties: false` member hiding other members' fields), `oneOf`/`anyOf`
  with discriminators, `if`/`then`/`else`, nullable types, recursion and fragment provenance.
- keep everything a keyword says: show it in the shape, word it as a rule or, when it can't be worded,
  fall back to a generic phrase ("the `if` schema matches", "mustn't match `not`").

**The model doesn't, by design:**

- prove a schema is unsatisfiable. Contradictions are shown as written:
  `{type: string, oneOf: [{type: integer}, {type: boolean}]}` is "one of integer or boolean", `enum` values
  the `type` rules out stay listed, a field that's both required and forbidden is shown as both. Only
  directly empty results are `nothing`: `false`, `not: {}`, and `allOf` members whose `type`s or `enum`s
  don't overlap.
- narrow a choice's variants by the outer `type`.
- work out which fields `unevaluatedProperties` sees. It's a rule only ("allows no unevaluated fields"),
  and the object stays open in the diagram.
- subtract types with `not: {type: …}`. That's a rule ("mustn't be null"), not a narrower `type`.
- merge `items` into the `prefixItems` positions of other `allOf` members. Each tuple position shows its
  own `prefixItems`.
- word conditions beyond the flat shape. An `if` is worded only when it checks fields' `const`, `enum`,
  `type` or presence, and a `then`/`else` only when it requires, forbids or limits fields directly.
  Anything else (`$ref`, `allOf`, nested fields, choices, dependencies) falls back to the condition's
  description, "the `if` schema matches" or "the `then` schema applies".
- apply `patternProperties` or an `additionalProperties` schema to named fields. Only
  `additionalProperties: false` in an `allOf` member forbids the other members' fields.
- check that `null` gets past every `oneOf`/`anyOf`. A nullable type is shown as "or null" even when a
  choice beside it rules null out.
- model `propertyNames`, `dependentSchemas`, `unevaluatedItems` or `$dynamicRef`
  (see `docs/backlog/model-ignores-some-keywords.md`).

A schema the model shows less strictly than the validator is **not a bug**, as long as no keyword is
silently dropped. A review finding about one of the cases above isn't a finding. Changing a boundary means
editing this page first, backed by real specs that need it.
