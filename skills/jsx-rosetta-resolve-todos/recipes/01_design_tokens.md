# Recipe 01 — Design tokens

## Shape

```
# TODO: (attribute|style declaration) "<name>" dropped — couldn't translate: <RHS>
<render Foo.new(...)>
```

…where `<RHS>` matches a token-system regex you've configured (e.g. `token\.(\w+)` for Ant Design, `theme\.palette\.(\w+)\.main` for MUI, `vars\.colors\.(\w+)` for vanilla-extract).

## Status

**Backed by `tools/apply_substitutions.rb`** — pure-Ruby mechanical pass, no LLM.

## Action

**Resolve** via `tools/apply_substitutions.rb`. This is a pure-Ruby pass — no LLM call, no agent dispatch.

```bash
ruby tools/apply_substitutions.rb \
  --config data/design_tokens.yml \
  <generated_components_dir>
```

Run this **before** any LLM-driven recipe so the corpus is smaller and cheaper to fan out over.

## How the substitution works

For each matched TODO, the script:

1. Looks up the captured key in the YAML's `tokens:` map.
2. Skips if the entry is missing or has `value: null` (explicitly opted out).
3. Locates the next single-line `render <Component>.new(...)` below the TODO.
4. Splices:
   - **style declaration** → into the existing string-literal `style:` (or creates a new `style:` kwarg)
   - **attribute** → as a snake_cased kwarg
5. Writes only if `ruby -c` passes on the result; otherwise reverts.

## When to skip / sharpen instead

The script handles the easy 60–75% of token TODOs. The cases it leaves untouched (and which a downstream recipe should sharpen, not blindly resolve):

- **Multi-line render calls.** When the render's argument list spans physical lines or uses hash-form `style: { ... }`, the script bails. Sharpening these requires Ruby-aware editing.
- **Template literals as RHS.** `` `${token.paddingSM}px ${token.padding}px` `` — multiple token refs woven into a string. Resolving this needs RHS evaluation, which the v1 script doesn't do.
- **Conditionals as RHS.** `!thumbnailUrl ? token.colorFillQuaternary : undefined` — the resolved color is conditional on runtime state, not a constant.
- **Component-namespace tokens.** `token.Tag.colorText`, `token.Layout.headerBg` — these depend on the consuming app's `ConfigProvider` overrides and have no safe default.

For each, sharpen to a TODO of the form:

```ruby
# TODO[design_token]: <attr> = <verbatim RHS>. Resolve to your <design system> theme value.
```

## Building the YAML for your design system

If your source codebase uses a known design system with default theming, check `examples/` first — it may already have a ready-made YAML you can use as-is.

Otherwise:

1. Run `tools/discover_bailouts.rb` on the generated corpus.
2. Identify the dominant root in the "Repeating member chains" section.
3. Copy `data/design_tokens.template.yml` to `data/design_tokens.yml`.
4. Paste the suggested `match:` regex.
5. For each top key, look up the design system's published default (or your theme override) and add an entry.
6. Run `apply_substitutions.rb --dry-run` to preview.
7. Drop `--dry-run` to commit the edits.
8. Re-run `discover_bailouts.rb` to confirm the count dropped.

## Anti-patterns

- **Don't** populate the YAML from training-data guesses about a design system you haven't verified. Token names and defaults change across versions; check the source codebase or the system's docs.
- **Don't** ship overrides specific to one consuming app in this skill's `data/` directory. App-specific overrides belong in the consuming repo's `.claude/skills/jsx-rosetta-resolve-todos/data/` (gitignored or scoped to that repo).
- **Don't** auto-resolve when the script reports `parse_failed` — investigate the input. The post-edit revert is a safety net, not a normal-path outcome.
