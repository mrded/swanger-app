---
worth: later
where: App/Swanger/DiagramView.swift:44
added: 2026-10-21
---
# zoomed-in diagram text is blurry

Zoom is a `scaleEffect` on the laid-out cards, so above 1× the text is a scaled-up bitmap: plainly soft
at 2–3× on a non-Retina display, less so on Retina. Crisp text means laying the cards out at the zoomed
size (scaling fonts and `DiagramMetrics`) instead of scaling a bitmap. Unsettled: whether that's worth it
given most use is at or below 1× on Retina screens.
