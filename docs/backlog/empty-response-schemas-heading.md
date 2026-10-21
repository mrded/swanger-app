---
worth: yes
where: App/Swanger/SpecSidebar.swift:16
added: 2026-10-21
---
# the sidebar shows an empty Response schemas heading

A spec whose responses have no JSON bodies (only a `204`) still gets a "Response schemas" heading with
nothing under it. Skip a root section when it's empty.
