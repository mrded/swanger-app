---
worth: yes
where: App/Swanger/SpecSidebar.swift:96
added: 2026-10-21
---
# search results cut off the schema name

A result's subtitle (`<schema> · <path>`) is truncated from the head, so a long path drops the schema
name, the one part that tells same-named fields apart. Searching `reference` in
`digital-waste-tracking-api-docs/docs/api/openapi-beta-2.yaml` gives five `reference` rows that all read
"…est · supportingReferences[].reference". Show the schema on its own line, or truncate the path
instead of the name. Seen in the task 9 hand check.
