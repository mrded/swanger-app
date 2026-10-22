---
worth: later
where: App/Swanger/DiagramView.swift:218
added: 2026-10-21
---
# ⌘-scroll may zoom too fast

In the diagram hand check of 2026-10-21, five small ⌘-scroll steps took the diagram from 2× to the 0.2× minimum.
Non-precise deltas are multiplied by 8 and then divided by 200, so each mouse-wheel line changes the
scale by about 40%. Those were synthesised events, though, so unsettled: how it feels with a real mouse
wheel and a trackpad. Check both before tuning.
