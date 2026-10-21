---
worth: yes
where: Sources/SwangerValidation/CompiledDocument.swift:38
added: 2026-10-21
---
# report the `$ref`-sibling bug to swift-json-schema

swift-json-schema (0.14.2, latest as of 2026-10-21) lets `additionalProperties` and `items` see the
`properties` and `prefixItems` of a `$ref` beside them. Nobody has reported it upstream. `CompiledDocument`
works around it by compiling `{$ref: X, …}` as `{allOf: [{$ref: X}], …}`; once upstream fixes it, the
rewrite can go (keep `additionalPropertiesBesideARefDoesntSeeItsFields` in `PayloadValidatorTests` as the
regression check).

Draft issue for https://github.com/ajevans99/swift-json-schema/issues:

> **`additionalProperties` / `items` see the `properties` / `prefixItems` of a sibling `$ref`**
>
> With `{"$defs":{"X":{"properties":{"a":{}}}},"$ref":"#/$defs/X","additionalProperties":false}`, the
> instance `{"a":1}` validates in 0.14.2. In 2020-12, `additionalProperties` only considers
> `properties`/`patternProperties` in the same schema object, so `a` is an additional property and the
> instance is invalid (ajv 8 agrees). The same schema written as `"allOf":[{"$ref":"#/$defs/X"}]` gives
> the correct result. `items` beside a `$ref` to a schema with `prefixItems` has the same problem.
