# Recipe 02 — Promoted-to-@ivar reminders

## Shape

```
# TODO: render condition references binding(s) promoted to @ivar — thread as controller-passed prop(s): <name1>, <name2>, ...
<valid Ruby that uses @<name1>, @<name2>>
```

## Status

**Backed by `tools/apply_promoted_ivar.rb`** — pure-Ruby mechanical pass, no LLM.

## Action

**Resolve / sharpen** via `tools/apply_promoted_ivar.rb`. Pure-Ruby, no LLM.

```bash
ruby tools/apply_promoted_ivar.rb [--dry-run] [--quiet] <file_or_dir>...
```

The script:

1. Parses each TODO's named prop list.
2. Reads the file's first `def initialize(...)` signature and extracts kwarg names.
3. Classifies each name:
   - **camelCase prop** present in `initialize` (after snake_casing) → satisfied
   - **camelCase prop** missing from `initialize` → flag as missing
   - **PascalCase identifier** → flag as external constant needing import/removal (these are class/enum references that `jsx_rosetta` couldn't resolve, not props you'd thread from a controller)
4. If every name is satisfied → **delete** the TODO entirely.
5. If anything is missing → **sharpen** to a tagged single-liner naming exactly what's missing:
   ```ruby
   # TODO[promoted_ivar]: controller must pass <missing_props> (not in def initialize); external constant(s) <PascalNames> need import or removal.
   ```

Always validates with `ruby -c` before writing; reverts on parse failure.

## Why this is mechanical

The Ruby below the TODO is already valid and correct. The reason `jsx_rosetta` emits it: when a JSX render condition refers to a name that was a top-level `const` or `import` in the source, it gets promoted to a `@<name>` ivar in Phlex output. The TODO reminds the author to thread that name from the controller. If the author already added it to `initialize`, the reminder is satisfied.

## Expected resolution rate

Depends on conversion stage:

- **Fresh translation, controllers not yet written** → close to 100% sharpen, 0% resolve. Pure compression win — verbose multi-line reminders become tagged single-liners that are grep-friendly and explicitly call out what each TODO needs (props vs imports).
- **After controllers are wired** → resolve rate climbs as `initialize` signatures gain the named props. Re-running the script becomes idempotent cleanup: each pass deletes any TODO whose props have caught up.

Run this script after `apply_substitutions.rb` and again any time you've updated a controller signature.
