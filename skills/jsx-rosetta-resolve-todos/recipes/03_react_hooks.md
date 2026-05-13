# Recipe 03 — React hooks

## Shape

```
# TODO: React hooks detected. None translate automatically.
# Hotwire/Stimulus handles behavior; controllers/views handle state;
# turbo-frames handle async loading. Original source:
#   <verbatim hook block>
```

## Status

**Documented intentions** — recipe describes the recommended LLM-driven action (the sub-classification table below is usable by an agent today); no backing tooling yet. Validation against a real conversion will inform whether parts of this become mechanical.

## Action

**Sharpen** by sub-classifying each hook in the dumped block. Default action per hook:

| Hook | Sharpened TODO template |
|---|---|
| `useState` | `# TODO[useState]: ephemeral UI state \`<name>\` (type <T>). Move to Stimulus controller value.` |
| `useMemo` | `# TODO[useMemo]: derived value \`<name>\`. Derive in controller and pass as @<name>; or extract to a helper if pure.` |
| `useRef` | `# TODO[useRef]: DOM ref \`<name>\`. Replace with Stimulus target: data-<controller>-target="<name>".` |
| `useEffect` | `# TODO[useEffect]: side effect. Split into Stimulus connect/disconnect (DOM lifecycle) or Turbo Frame load (async).` |
| `useCallback` | (drop — no React render model means no value) |
| Custom `use*` | `# TODO[custom-hook]: \`<name>\` — review and reimplement; no automatic mapping.` |

Preserve the original block as `# Original:` for traceability.

## When to escalate

- Hook with significant computation that would change behavior if naively moved
- Custom hooks that wrap data fetches, subscriptions, or business logic
