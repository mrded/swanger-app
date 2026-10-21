---
worth: yes
where: App/Swanger/DiagramCards.swift:177
added: 2026-10-21
---
# a closed object's card says so twice

A card for an object with `additionalProperties: false` ends with the rule "allows no other fields"
(from `SchemaBuilder+Facts.swift`) and then the note "No other fields" (from `cardNotes`). Every object
card in `openapi-beta-2.yaml` shows both. Keep one.
