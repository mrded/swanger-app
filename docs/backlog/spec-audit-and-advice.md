---
worth: later
added: 2026-10-21
---
# audit a spec: find abandoned fragments and give advice

Add a way to audit the open spec: list `components/schemas` entries that no request or response body
reaches (abandoned fragments), and give advice on other things worth tidying. Today Swanger can't show
these at all: `Spec.fragments` only holds fragments the roots reach, so an unused component never
appears anywhere. Unsettled: what else the audit should check beyond unused fragments, and where it
lives (an overview section, its own page, or an inspector panel). Pick the checks before building it.
Related: `root-listed-as-its-own-fragment.md` also turns on what counts as a fragment "use".
