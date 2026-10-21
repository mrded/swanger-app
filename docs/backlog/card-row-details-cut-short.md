---
worth: yes
where: App/Swanger/CardView.swift:130
added: 2026-10-21
---
# card row details are cut short

Row details truncate in the middle at the fixed 270pt card width and lose the part that matters:
`method =…-transfer"` for the BankTransfer variant in the Shop fixture, `one of Hous…r Municipal` for
`producer` in `openapi-beta-2.yaml`. Options: let the label give way instead, widen cards that need it,
or show a shorter detail ("one of 3") and leave the rest to the inspector. Seen in the task 9 hand check.
