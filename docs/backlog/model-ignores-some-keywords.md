---
worth: later
where: Sources/SwangerCore/Model/SchemaBuilder.swift:817
added: 2026-10-20
---
# the model ignores propertyNames, dependentSchemas, minContains/maxContains, unevaluatedItems and $dynamicRef

These keywords only mark a node as an object or array (they're in `objectKeywords`/`arrayKeywords`);
none of them becomes a rule or part of the shape, so the diagram shows such schemas as less constrained
than they are. `$dynamicRef` isn't followed at all.

Unknown: whether real API specs use any of these. Run item 4 of `find-model-edge-cases` (a spec corpus)
and count them; if they're absent, drop this as `no`, otherwise word the common ones as rules.
