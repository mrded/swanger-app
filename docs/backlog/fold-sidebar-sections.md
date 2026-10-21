---
worth: yes
where: App/Swanger/SpecSidebar.swift:15
added: 2026-10-21
---
# can't fold sidebar sections

The sidebar's "Request schemas", "Response schemas" and "Shared fragments" sections are always open.
In a large spec, a long fragment list pushes everything else out of sight. Let each section fold, e.g.
`Section(isExpanded:)`, and remember the folded state per window or per spec.
