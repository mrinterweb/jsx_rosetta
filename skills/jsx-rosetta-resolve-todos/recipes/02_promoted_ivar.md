# Recipe 02 — Promoted-to-@ivar reminders

## Shape

```
# TODO: render condition references binding(s) promoted to @ivar — thread as controller-passed prop(s): <name1>, <name2>, ...
<valid Ruby that uses @<name1>, @<name2>>
```

## Status

**STUB.** This recipe should be backed by `tools/apply_promoted_ivar.rb` (not yet built — same shape as `apply_substitutions.rb`, no LLM, mechanical).

## Action

**Resolve** mechanically:

1. Parse the prop name(s) from the TODO message.
2. Inspect the file's `def initialize(...)` signature.
3. If every named prop appears as a kwarg in `initialize`, delete the TODO comment. The Ruby below it is already correct — the TODO was a reminder, not a defect.
4. If any prop is missing, sharpen to:
   ```ruby
   # TODO[promoted_ivar]: controller must pass <missing_props>; not currently in def initialize.
   ```

## Why this is mechanical

The Ruby below the TODO is already valid and correct. The reason `jsx_rosetta` emits it: when a JSX render condition refers to a name that was a top-level `const` or `import` in the source, it gets promoted to a `@<name>` ivar in Phlex output. The TODO reminds the author to thread that name from the controller. If the author already added it to `initialize`, the reminder is satisfied.

Expected resolution rate: very high (~90%+) once the consuming repo's controllers have been wired up. Earlier in a conversion, expect lower — many will sharpen to "missing in initialize."
