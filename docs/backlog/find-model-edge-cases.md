---
worth: yes
where: Tests/SwangerCoreTests/Model/ValidatorAgreementTests.swift:15
added: 2026-10-20
---
# no systematic way to find the model's remaining edge cases

Ten review rounds on step 6 each found new keyword-combination bugs in the schema model (`allOf` ×
`$ref` × `type` × `oneOf` × `if` × null …); fixing them one review at a time kept introducing new ones.
`ValidatorAgreementTests` now compares the model with swift-json-schema for 29 atoms, alone and in pairs,
four ways combined and three contexts, but it only checks one direction: everything the validator accepts,
the model must accept. A model that is too strict is caught; one that silently drops a constraint is not
(e.g. `{type: number, not: {type: integer}}` losing its rule was found by review, not by the test).

Ways to find the rest, roughly in order of value:

1. **Too-permissive direction.** A small checker for what the model claims — types, allowed values,
   required and forbidden fields, closed objects, length/range/item-count limits — run on each sample. Any
   sample the model's claims accept but the validator rejects, with no rule on the node explaining it,
   is a dropped constraint.
2. **Generated samples.** Build sample values from each case's own `enum`/`const` values, `required` and
   property names, pattern-matching names and tuple lengths, instead of the 24 fixed ones. The
   "possibly impossible" report is mostly sample-coverage noise today (e.g. no sample has both `b` and
   `k`); with generated samples it becomes a real signal and could be made to fail.
3. **Triples.** A seeded random sample of three-atom combinations: some bugs only appear with three
   (e.g. `type: [object, null]` + `required` + a `false` property).
4. **Real specs.** Run the model and the validator over a corpus of public specs (APIs.guru's
   `openapi-directory`) on their own examples, and report disagreements plus any keywords the model
   ignores. This also settles `model-ignores-some-keywords` and `impossible-oneof-shown-as-choice`.
5. Optionally, a dev-only cross-check of merged keywords against `allof-merge` (JS, via JavaScriptCore or
   node in the test run). Not to ship: it flattens away fragment provenance, which is the model's point.

The swift-json-schema `$ref`-sibling bug the test works around is tracked in step 7 of the plan.
