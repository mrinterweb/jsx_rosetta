---
name: jsx-rosetta-resolve-todos
description: Resolve the `# TODO:` comments left by jsx_rosetta in generated Phlex / ViewComponent files. Mechanical substitution for known patterns (design tokens, prop-passing reminders); LLM-driven recipes for hooks, data-fetching, event handlers, navigation, and module constants; sharpened-TODO emission for everything else.
---

# jsx-rosetta-resolve-todos

`jsx_rosetta` translates JSX/TSX into Phlex / ViewComponent / ERB and is intentionally conservative: when an expression can't be safely lowered, it preserves the original JS verbatim inside a `# TODO:` comment. This skill is the last-mile companion for converting that output into shippable Rails code.

It does **not** speculate. The hard rule, inherited from the gem itself: prefer leaving a sharper TODO over guessing wrong. Three actions per TODO:

- **resolve** — apply a known transformation, delete the TODO
- **sharpen** — replace a verbose TODO with a tighter one a human can clear in seconds
- **escalate** — leave untouched, surface in the report

## Per-file workflow

```
1. Run `ruby -c <file>` to confirm the file parses before any edits.
2. Walk TODOs top-to-bottom. Classify each against the routing table below.
3. Dispatch to the matching recipe. Take exactly one of {resolve, sharpen, escalate}.
4. Re-run `ruby -c`. If parsing breaks, REVERT and report `parse_failed` —
   never ship a half-edit.
5. Emit a JSON line with category counts.
```

The mechanical pre-passes (design tokens, promoted-@ivar reminders) run as standalone scripts with no LLM involved. Run them first; they're fast, safe (always `ruby -c`-validated before write), and remove a meaningful chunk of TODOs before any agent dispatch happens.

## Routing table

The TODO comments emitted by `jsx_rosetta` follow stable shapes. Routing is regex-based:

| TODO regex | Recipe | Default action | Backing |
|---|---|---|---|
| `# TODO: (attribute\|style declaration) "X" dropped — couldn't translate: <RHS>` (RHS matches a configured token regex) | `recipes/01_design_tokens.md` | resolve via `tools/apply_substitutions.rb` | **script** |
| `# TODO: render condition references binding\(s\) promoted to @ivar` | `recipes/02_promoted_ivar.md` | resolve or sharpen via `tools/apply_promoted_ivar.rb` | **script** |
| `# TODO: React hooks detected` | `recipes/03_react_hooks.md` | sharpen — sub-classify hook flavor | docs only |
| `# TODO: Apollo data-fetching hooks detected` | `recipes/04_apollo_hooks.md` | sharpen — extract query name + variables | docs only |
| `# TODO: translate the original JSX `<event>` handler` | `recipes/05_event_handlers.md` | sharpen — classify behavioral vs mutation | docs only |
| `# TODO: module-level constants` | `recipes/06_module_constants.md` | dispatch by sub-type | docs only |
| `# TODO: Next.js navigation hooks detected` | `recipes/07_nextjs_navigation.md` | sharpen — extract route + params | docs only |
| `# TODO: translate JS to Ruby — original:` | `recipes/08_generic_js_bailouts.md` | always sharpen | docs only |
| `# TODO: (attribute\|style declaration) "X" dropped` (RHS doesn't match any token regex) | `recipes/08_generic_js_bailouts.md` | always sharpen | docs only |

**Backing column legend:**
- **script** — pure-Ruby tool ships with the skill. No LLM required; safe to run unattended.
- **docs only** — recipe text is usable today by an LLM agent (e.g. via `jsx-rosetta-resolve-todo-file`). No mechanical tool yet; sub-classification and sharpening are agent work.

When in doubt, sharpen.

## Tools

### `tools/discover_bailouts.rb`

Pure-Ruby corpus scanner. Tallies dropped-expression RHS values, finds repeating member chains (`<root>.<member>...`), and suggests a `match:` regex per cluster. Use it to decide what's worth automating before you build any tables or recipes.

```bash
ruby tools/discover_bailouts.rb [--top N] [--json] [--all-todos] <file_or_dir>...
```

Output identifies the dominant "roots" in your corpus (`token`, `theme`, `vars`, etc.) — these are your candidate design-system / config namespaces. The script makes no claim about what they *mean*; that's your call.

### `tools/apply_substitutions.rb`

Pure-Ruby mechanical substitution. Reads a YAML config that declares a `match:` regex and a `tokens:` map; finds matching TODOs, splices values into the `render Foo.new(...)` immediately below.

```bash
ruby tools/apply_substitutions.rb --config <yaml> [--dry-run] [--quiet] <file_or_dir>...
```

Conservative by design:

- Only single-line `render Foo.new(...)` calls
- String-literal `style:` attribute (or absent); hash-form `style: { ... }` is skipped without false edits
- Skips drops whose attribute name would produce an invalid Ruby identifier
- Pre-write `ruby -c` validation; on failure, the file is left untouched and the run is reported as `parse_failed`

See `examples/design_tokens.ant_design_v5.yml` for a full reference config (Ant Design v5 defaults, ~85 tokens). See `data/design_tokens.template.yml` for a blank schema you can fill in for your own design system.

### `tools/apply_promoted_ivar.rb`

Pure-Ruby resolution of the `# TODO: render condition references binding(s) promoted to @ivar` reminders. Reads each file's `def initialize` signature and either deletes the TODO (when every named prop is already in the signature) or sharpens it to a tagged single-liner naming exactly what's missing — distinguishing missing controller props from missing PascalCase imports.

```bash
ruby tools/apply_promoted_ivar.rb [--dry-run] [--quiet] <file_or_dir>...
```

Idempotent: safe to re-run after wiring more controllers.

### Recipe content (`recipes/*.md`)

Each recipe describes:
- The TODO shape it handles
- The transformation rule (resolve) or the sharpened-TODO template (sharpen)
- What information to grep from the host Rails app
- When to escalate

Recipes are loaded by the `jsx-rosetta-resolve-todo-file` agent (one per file) for fan-out work, and by the human running the skill in interactive mode.

## Sharpened-TODO format

A sharpened TODO must include:

1. **What** the source was doing in one phrase — no JS dump.
2. **Where** the resolution belongs in Rails (controller / helper / Stimulus / view).
3. **What's missing** — the unanswered question that prevents resolution.
4. The original JS preserved in an indented `# Original:` block below.

Template:

```ruby
# TODO[<category>]: <one-line what>. <where it belongs>. <what's needed>.
# Original:
#   <verbatim JS, indented>
```

Example transformation. Before:

```ruby
# TODO: React hooks detected. None translate automatically.
# Hotwire/Stimulus handles behavior; controllers/views handle state;
# turbo-frames handle async loading. Original source:
#   const [open, setOpen] = useState(false);
```

After:

```ruby
# TODO[useState]: ephemeral UI state `open`. Move to Stimulus controller value: { open: Boolean }.
# Original:
#   const [open, setOpen] = useState(false);
```

The `[<category>]` tag is grep-friendly — humans can filter by tag to batch similar decisions.

## Modes

### Single-file (interactive)

The skill is invoked on a specific file. Workflow runs in the main conversation context. Use when reviewing the result yourself or when the file has unusual shape that the recipes won't handle cleanly.

### Batch (fan-out)

The skill walks a directory and dispatches one `jsx-rosetta-resolve-todo-file` agent per file (or per chunk). Each agent loads the recipes from this skill's directory, processes its file, and emits a JSON report. The skill aggregates reports into a corpus-level summary.

Recommended order in batch mode:

1. **Discovery pass** (`discover_bailouts.rb --json`) — surface what's worth mapping.
2. **Mechanical pre-passes** (`apply_substitutions.rb` for each design-system YAML you have, plus `apply_promoted_ivar.rb`) — strip out the trivially-mechanical TODOs first. No LLM, no agent.
3. **Agent fan-out** — for what's left, one `jsx-rosetta-resolve-todo-file` worker per file. Workers are tool-restricted (Read, Edit, Bash for `ruby -c`, Grep) and stateless. Sonnet 4.6 is the right tier; Opus is overkill for recipe application; Haiku is too light for the surrounding-code reading the recipes need.
4. **Re-run discovery** to confirm what was resolved and what's left to escalate to a human.

## Configuration the user owns

This skill ships with no app-specific assumptions. The files you (the consuming user) own:

- `data/design_tokens.yml` (or any other YAML you point `apply_substitutions.rb` at). Created from `data/design_tokens.template.yml` or copied from `examples/`.
- `data/target_app_conventions.yml` — paths, naming, CSS strategy. Recipes 03–07 read this to know where extracted helpers, controllers, and Stimulus controllers belong in your Rails app. Without it, recipes sharpen with `<TBD: see target_app_conventions.yml>` rather than guessing. Copy `data/target_app_conventions.template.yml` to seed it.

Anything in `data/` other than `*.template.*` should be `.gitignored` in the consuming repo if it contains overrides specific to that app's theme or conventions.

## Scope

This skill addresses the corpus of `# TODO:` comments that `jsx_rosetta` emits. It does not:

- Re-translate JSX (that's `jsx_rosetta` itself)
- Touch business logic
- Make architectural decisions about how a React app should map to Rails (controllers vs. service objects, Turbo Frames vs. plain links, etc.) — those are flagged for human review via sharpened TODOs

Effort expectation: a meaningful fraction of TODOs reflect genuine human-judgment decisions and will not auto-resolve under any system. The skill's value is auto-resolving the mechanical chunk and compressing the rest into single-decision items. See "Validation" below for measured impact on the gem's own stress corpus.

## Validation

Measured against the `jsx_rosetta` gem's own Phlex stress corpus (1,245 generated `.rb` files, 4,846 `# TODO:` comments) using `tools/diff_corpus.rb`. The corpus represents a *fresh translation* — controllers haven't been wired yet, so promoted-ivar TODOs sharpen rather than resolve.

| Pass | Files modified | TODOs resolved | TODOs sharpened | Parse failures |
|---|---|---|---|---|
| `apply_substitutions.rb --config examples/design_tokens.ant_design_v5.yml` | 158 / 1,245 | 336 | 0 | 0 / 1,245 |
| `apply_promoted_ivar.rb` | 333 / 1,245 | 0 (corpus state) | 665 | 0 / 1,245 |
| **Combined mechanical pre-pass** | **428 / 1,245** | **336 deleted** | **665 compressed** | **0 / 1,245** |

Net change: 4,846 → 4,510 TODO comments. Of the 1,001 TODOs the mechanical passes touched:

- 336 were deleted outright (Ant Design token references → literal values spliced into render calls)
- 665 were compressed from verbose multi-line reminders into tagged single-liners (`# TODO[promoted_ivar]: controller must pass <names>...`) with explicit "missing prop" vs "missing import" verdicts

The 117 unaddressed token TODOs are conservative bailouts (multi-line render shapes, hash-form `style:`, complex RHS expressions) that the substitution script intentionally skips rather than risk breaking output.

What's *not* measured here:

- The LLM-driven recipes (03–08) — they ship as documented intentions; their resolve/sharpen rate depends on a live conversion to validate against.
- The remaining ~3,500 TODOs are concentrated in categories (`react_hooks` 378, `event_handler` 428, `module_constants` 355, `apollo_hooks` 222, `nextjs_navigation` 105, generic JS bailouts 1,053) where the recipes default to *sharpening* — measurable as compression once an agent runs the recipes on a real corpus.

Reproduce with:

```bash
ruby tools/diff_corpus.rb <baseline_dir> <after_pipeline_dir>
```

## Future work

Tracked here so the skill's roadmap is visible alongside its current shape:

- **Cross-file context for fan-out workers.** Today each `jsx-rosetta-resolve-todo-file` worker is stateless — the same gql query referenced from 5 files would sharpen identically 5 times. A pre-pass that builds a project-wide "discovery digest" (recurring queries, recurring helpers, controller signatures already seen) and feeds it to each worker would let the corpus learn once. Hard to design ahead of real-conversion evidence; bolt-on later.
- **Drift-detection spec.** The TODO regexes in this skill's recipes need to stay in sync with the strings emitted by `lib/jsx_rosetta/backend/phlex.rb`. One round-trip test per category (fixture → translate → resolve-todos → assert N matched) would catch silent emit-format drift. Worth doing once more recipes are backed by scripts; testing stub recipes is testing a sketch.
- **Backing scripts for recipes 03–08.** Some sub-classifications (e.g. recipe 03's hook → Stimulus mapping for unambiguous shapes like `useState(false)`) may be mechanical enough to ship as scripts. Others (event handler classification, gql operation extraction) probably stay LLM-driven. The split will become clear after running the recipes on a real conversion.
