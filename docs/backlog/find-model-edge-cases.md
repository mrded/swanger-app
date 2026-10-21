---
worth: yes
where: Tests/SwangerCoreTests/Model/ValidatorAgreementTests.swift:15
added: 2026-10-20
---
# the agreement test's samples and atoms miss real-world shapes

`ValidatorAgreementTests` is the only correctness bar for keyword combinations (see Model boundaries in
the plan), but its 25 fixed samples and 29 hand-written atoms limit what it can catch. Two ways to widen it
without chasing rare combinations:

1. **Generated samples.** Build sample values from each case's own `enum`/`const` values, `required` and
   property names, pattern-matching names and tuple lengths, instead of the fixed ones. The "possibly
   impossible" report is mostly sample-coverage noise today (e.g. no sample has both `b` and `k`); with
   generated samples it becomes a real signal and could be made to fail.
2. **Real specs.** Run the model and the validator over a corpus of public specs (APIs.guru's
   `openapi-directory`) on their own examples, and report disagreements plus any keywords the model
   ignores. Wider than task 11's Petstore and one large spec; it also settles
   `model-ignores-some-keywords`.
