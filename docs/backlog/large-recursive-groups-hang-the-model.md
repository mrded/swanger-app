---
worth: yes
where: Sources/SwangerCore/Model/SchemaBuilder.swift:169
added: 2026-10-21
---
# Large groups of mutually recursive schemas hang the model (Stripe's spec)

Opening Stripe's spec ([stripe/openapi](https://github.com/stripe/openapi) `openapi/spec3.json`,
8 MB) never finishes: `Spec.load` was still building the model after 10 minutes. Sampling shows it
in `SchemaBuilder.fragmentContent` / `build` / `merge`.

The cause is the recursion rule ("the second visit to a schema on the same path becomes
`recursive`"). A fragment's tree is cached only when it has no recursive references to fragments
outside itself (`built.escapes.isEmpty`), so inside a group of mutually recursive schemas every
fragment is rebuilt for every path that reaches it. The tree enumerates every simple path through
the group, which is exponential in the group's size. Stripe has a strongly connected group of 97
schemas (and one of 14). GitHub's spec has none, which is why it loads in about 8 s unoptimised.

Caching alone can't fix it, because the trees themselves are that big. The rule has to change. For
example, once a path is inside a recursive group, show a reference to another member of the group as
`recursive` after the first one or two members, rather than only when the same member repeats. Small
cycles such as Order ⇄ Customer should keep looking the way they do now. That changes a boundary, so
edit `docs/model-boundaries.md` first. Then add Stripe back to
`scripts/fetch-real-world-specs.sh` (pinned at `f3799ad599a6cf7c76fd94ce72274c0367cc2ba7`, SHA-256
`7cff4cc46d0654101a36a3302f7544640f5f73e4f3cad6f264f0e23c19fa1776`) and to `RealWorldSpecTests`.

Until then, the app shows the loading spinner forever for such a spec and keeps a CPU core busy.
