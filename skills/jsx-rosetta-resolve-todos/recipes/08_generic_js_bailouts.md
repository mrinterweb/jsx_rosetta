# Recipe 08 — Generic JS bailouts

## Shape

```
# TODO: translate JS to Ruby — original:
#   <verbatim JS expression or block>
```

…or any "<X> dropped" TODO whose RHS doesn't match a configured token regex.

## Status

**Documented intentions** — recipe describes the recommended LLM-driven action; no tooling yet. Always-sharpen by design (see below).

## Action

**Always sharpen. No resolve whitelist.**

This is the largest, most heterogeneous TODO category and the one most prone to "looks easy" hazards. Earlier drafts of this recipe carried a small whitelist (`String(x) → x.to_s`, `x ?? y → x || y`, etc.); on review every entry had at least one observable-behavior divergence:

| Tempting JS → Ruby | Why it's wrong |
|---|---|
| `Number(x)` → `x.to_f` | JS returns `NaN` on bad input; Ruby returns `0.0` |
| `Boolean(x)` → `!!x` | JS-falsy `0`, `""` are Ruby-truthy |
| `String(x)` → `x.to_s` | Diverges on `null`/`undefined` |
| `x ?? y` → `x \|\| y` | `??` is null/undefined-only; `\|\|` checks all falsy |
| `Array.isArray(x) ? x[0] : x` → `Array(x).first` | Object inputs become `[k,v]` tuples in Ruby |

The gem's hard rule applies here too: **if `jsx_rosetta` bailed, it's not safe**. The gem already attempts every translation that has unambiguous semantics; a generic JS bailout is by definition something it considered unsafe to translate. This recipe inherits that posture.

## Sharpen template

Replace the multi-line dump with:

```ruby
# TODO[js_bailout]: <one-line description of what the source computes>.
#   Move to <controller / helper / Stimulus> — needs <what info>.
# Original:
#   <verbatim, indented>
```

If the bailout's intent isn't clear from a single read, just preserve and tag — don't invent a description. A truthful "see Original" is more useful than a guessed summary.

## When to escalate

- Bailouts that touch authentication, authorization, or business invariants
- Bailouts whose Ruby equivalent would change observable behavior
- Anything whose JS uses APIs without obvious Ruby/Rails equivalents (`navigator.*`, `window.*`, browser-only globals)

## Anti-patterns

- **Don't** add to the resolve whitelist. If a future class of bailout has genuinely unambiguous semantics, the right home is the gem itself, not this recipe — the gem will then stop emitting the bailout in the first place.
- **Don't** translate function calls whose Ruby/Rails equivalent isn't in the consuming app. Sharpen instead so the human can introduce the helper deliberately.
- **Don't** speculate about author intent. The verbatim JS is the most useful artifact when the worker can't classify with confidence.
