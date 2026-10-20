---
worth: later
where: Sources/SwangerCore/Model/SchemaBuilder.swift:325
added: 2026-10-20
---
# an unsatisfiable oneOf is still shown as a choice

A `oneOf` whose variants all match the same values can't be satisfied, but the model shows it as a
choice. It happens when the outer `type` narrows variants until they're identical (`{type: string, oneOf:
[{required: [k]}, {required: [m]}]}` becomes "one of string or string", since `required` doesn't apply to
strings), or when variants overlap. Seen in the "possibly impossible" report of `ValidatorAgreementTests`.

Unknown: whether real specs contain it, or whether it only arises from contradictory schemas. The corpus
run in `find-model-edge-cases` would tell; detecting overlap in general needs the too-permissive checker
from that item too.
