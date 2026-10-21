---
worth: yes
where: Sources/SwangerCore/References/RefResolver.swift:244
added: 2026-10-21
---
# `$ref`s to a schema's `$id` or `$anchor` aren't followed

The Swagger Petstore 3.1 (`Tests/SwangerCoreTests/Fixtures/real-world/petstore-3.1.json`) gives its
components `$id`s and refers to them by those, plus a named anchor:

```json
"Pet": { "properties": {
  "petDetailsId": { "$ref": "/api/v31/components/schemas/petdetails#pet_details_id" },
  "petDetails":   { "$ref": "/api/v31/components/schemas/petdetails" } } },
"PetDetails": { "$id": "/api/v31/components/schemas/petdetails",
  "properties": { "id": { "$anchor": "pet_details_id", ... } } }
```

Both become unresolved warnings: the first because named anchors aren't supported, the second because
it's read as a relative file path. `RealWorldSpecTests.petstore31` pins exactly these two warnings, so
it fails (on purpose) once this is fixed. Update it then.

What a fix needs, which is why it wasn't done inline in task 11:

- `RefResolver` resolving each `$ref` against the nearest enclosing `$id` (the base URI), not only the
  file, and an index of every `$id` and `$anchor` in each loaded document.
- `CompiledDocument` (`SwangerValidation`) dropping or rewriting `$id`s when it copies schemas into
  `$defs`. Otherwise the validator resolves the rewritten `#/$defs/…` refs against the wrong base.
- Tests for `$id` with relative refs below it, `$anchor`, and an `$id` that clashes with a file name.
