# Recipe 06 — Module-level constants

## Shape

```
# TODO: module-level constants — translate to Ruby constants or move to a Rails initializer:
#   <verbatim const / function / template-tagged block(s)>
```

## Status

**Documented intentions** — recipe describes the recommended LLM-driven action; no backing tooling yet. The per-declaration sub-type table below is usable by an agent today.

## Action

**Dispatch by sub-type.** Walk the dumped block and classify each declaration:

| Sub-type | Action |
|---|---|
| `const X = gql(...)` | Sharpen: "GraphQL operation — see recipe 04 (Apollo). Move to controller." |
| `function foo(...) { ... }` (pure) | Sharpen: "Helper — extract to `app/helpers/<name>_helper.rb` (view-scoped) or `app/services/` (app-wide)." |
| `const X = lazy(() => import(...))` | Sharpen: "Lazy-loaded component — wrap render in a Turbo Frame `src=` instead." |
| `const X = { ... } as const` (lookup map) | **Resolve**: emit Ruby `X = { ... }.freeze` at top of file. |
| `const X = "literal"` / `const X = 42` | **Resolve**: emit Ruby constant or local. |
| Other | Sharpen with verbatim body and "no recipe — review." |

## Why per-declaration

A single `module-level constants` block can contain multiple unrelated things (a gql query AND a lookup table AND a helper function). Splitting per-declaration lets each piece take its proper Rails-shaped destination.
