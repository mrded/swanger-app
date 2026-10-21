---
worth: yes
where: App/Swanger/OverviewPage.swift:125
added: 2026-10-21
---
# usage grid column headers are cut short

The rotated column headers have a fixed 130pt length, so "updateOrderStatus request" shows as
"updateOrderStatus requ…" in the Shop fixture even with plenty of room above the grid. Size the header
row to the longest name (with a cap), or wrap. The full name is only in a tooltip. Seen in the task 9
hand check.
