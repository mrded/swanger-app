---
worth: later
added: 2026-10-21
---
# a root component shows as a fragment its own root uses

When a body is a `$ref` to a component, that component is the root and also listed as a shared
fragment that the root "uses directly": in the Shop fixture NewOrder in the NewOrder column, Order in
Order, Category in `listCategories 200 response`. NewOrder is genuinely shared (Order's `allOf` uses
it), but Order and Category only "use" themselves, which reads as noise in the grid and the sidebar.
Unsettled: whether a root's own component should count as a usage at all, given the scope in
`docs/architecture.md`: "every `components/schemas` entry they reach is a shared fragment". Decide
that before changing `FragmentIndex`.
