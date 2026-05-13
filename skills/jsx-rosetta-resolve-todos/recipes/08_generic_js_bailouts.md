# Recipe 08 — Generic JS bailouts

## Shape

```
# TODO: translate JS to Ruby — original:
#   <verbatim JS expression or block>
```

…or any "<X> dropped" TODO whose RHS doesn't match a configured token regex.

## Status

**STUB.** Full recipe to be written.

## Action

**Default: sharpen.** This is the largest, most heterogeneous category. The project rule is explicit: prefer leaving a sharper TODO over speculative JS-to-Ruby translation.

### Resolve (whitelist only)

The following JS shapes have safe 1:1 Ruby equivalents. Resolve when the bailout RHS exactly matches one:

| JS shape | Ruby |
|---|---|
| `String(x)` | `x.to_s` |
| `Number(x)` | `x.to_f` (or `.to_i` if integer-typed in source) |
| `Array.isArray(x) ? x[0] : x` | `Array(x).first` |
| `x ?? y` | `x \|\| y` |
| `x ?? <default literal>` | `x \|\| <literal>` |
| `Boolean(x)` | `!!x` |
| Inline `const X = "literal"` / `const X = <number>` | Ruby local at top of `view_template` |

Whitelist is conservative on purpose — every entry should have unambiguous semantics across both languages.

### Sharpen (default)

For everything else, replace the multi-line dump with:

```ruby
# TODO[js_bailout]: <one-line description of what the source computes>.
#   Move to <controller / helper / Stimulus> — needs <what info>.
# Original:
#   <verbatim, indented>
```

If the bailout's intent isn't clear from a single read, just preserve and tag — don't invent a description.

## When to escalate

- Bailouts that touch authentication, authorization, or business invariants
- Bailouts whose Ruby equivalent would change observable behavior
- Anything whose JS uses APIs without obvious Ruby/Rails equivalents (`navigator.*`, `window.*`, browser-only globals)

## Anti-patterns

- **Don't** extend the whitelist with shapes that have semantic edge cases. `==` vs `===`, `null` vs `undefined`, `[]` vs `Array(...)` — each of these has corner cases that make a "looks easy" rewrite a hazard.
- **Don't** translate function calls whose Ruby/Rails equivalent isn't in the consuming app. Sharpen instead so the human can introduce the helper deliberately.
