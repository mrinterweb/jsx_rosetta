# Slice A — translator widening (umbrella: `translator_widening_and_pages_followups.md`)

Three independent translator changes that reduce TODO noise across every translated file. Self-contained — no Next.js / pages-routing surface area.

Items from the umbrella plan:

- **A1** — Conditional-render path: simple identifier / member-chain / unary tests over known bindings emit `@ivar` (or a short rendered form) with a single migration TODO, instead of the current `# TODO: translate condition: <expr>` + `if false` fallback. **Stress corpus target: ~123 TODOs (`render guard` ladder collapses + `simple-condition` lines).**
- **A2** — Literal-shaped module-level `const` declarations (string / number / boolean / null / array of literals / object of literals) lower to `IR::ModuleConstant`. The Phlex backend emits them as real Ruby constants above the class, alongside cva constants. Non-literal initializers still fall through to the existing module-binding TODO block. **Stress corpus target: ~402 TODO blocks affected.**
- **A3** — `router.push("/path")` references inside `useEffect` / non-handler hook bodies trigger a `# → redirect_to <helper>` annotation above the hook TODO when the route table is present. Handler bodies (`onClick={() => router.push(...)}`) stay verbatim per the project rule. **Stress corpus target: <50 occurrences, high-signal where it fires.**

## A1 — Conditional-render widening

### Diagnosis

`safe_test_expression` in `backend/phlex.rb:894` calls `translator.translate(expression)`. The translator already handles bare identifiers / member chains / unary `!` correctly in *attribute-value* contexts. For *render-condition* contexts the same shapes produce one of two failures:

1. **`"nil"` literal result** — bucket-4 hits (known-but-unresolvable locals from hook destructures, top-level `const`, or imports) translate to `"nil"` at the leaf-identifier position so the file loads in attribute-value contexts. Driving `if nil` silently false-arms the branch, so `safe_test_expression` upgrades that to the `false` fallback + TODO.

2. **Translator bail (`nil` return)** — for `member-chain root`, `unary operand`, `binary operand`, bucket 4 returns `nil` to bail the whole translation. The conditional then emits `if false` + TODO.

In both cases the user reads a verbatim JS expression in a comment and has to wire the Rails side manually.

### Widening rule (render-condition context only)

Add a new `ExpressionTranslator#translate_condition(source)` entry point. Same recursive translator, but identifier resolution differs for **bucket 4** (known-but-unresolvable locals + imports):

| Position | Old behavior | New behavior |
|---|---|---|
| Leaf identifier | `"nil"` | `"@snake_case"` + record-as `condition_promoted_to_prop` |
| Member-chain root | bail (return nil) | `"@snake_case"` + record + recurse into chain |
| Unary `!` operand | bail | translate as above, prefix `!` |
| Binary operand | bail | translate as above |

Bucket-3 (props) and bucket-1 (local scope) keep their existing translations. Bucket-2 prop aliases unchanged.

The promoted name set comes back via a new field on `Result` (or a sidecar accessor). `safe_test_expression` surfaces the names as a *single, short* TODO line above the `if`, e.g.:

```ruby
# TODO: render condition `loading` references binding promoted to @loading — thread it as a controller-passed prop
if @loading
  # …
end
```

instead of the current

```ruby
# TODO: translate condition: loading
if false
  # …
end
```

### Why not just always-widen in attribute-value contexts too

Attribute-value uses (`disabled={loading}`) want the bucket-4 leaf to render *something* even when no migration plan exists (the `nil` placeholder is intentional — the page loads and the reviewer fixes it). Promoting to `@loading` everywhere would silently NameError if the user never threads the prop. Render-condition context is the safe place to widen because the test is *load-bearing* — emitting `if false` already destroys the branch's intent, so promoting beats silence.

### Files

| Path | Status | Scope |
|---|---|---|
| `lib/jsx_rosetta/backend/view_component/expression_translator.rb` | modify | New `translate_condition(source)` entry point + a `@condition_mode` flag that flips bucket-4 behavior. Track promoted names in a per-translation accumulator. |
| `lib/jsx_rosetta/backend/phlex.rb` | modify | `safe_test_expression` calls the new entry point. `emit_conditional_branches` and `render_guard_ladder_collapse` emit a one-line promoted-binding TODO above the branch (or above the ladder) instead of the verbose verbatim-JS TODO. |

### Specs

| Path | Status | Coverage |
|---|---|---|
| `spec/backend/view_component/expression_translator_spec.rb` | modify | `translate_condition` results for hook-tuple destructure, top-level import, member-chain over local, unary `!loading`. |
| `spec/backend/phlex_spec.rb` | modify | Conditional render emits `if @ivar` with TODO header naming the promoted binding. Guard ladder ditto. |

## A2 — Literal module-level const → Ruby constant

### Detector

Mirror `parse_cva_binding` in `lib/jsx_rosetta/ir/lowering.rb`. The detector accepts an `init` node and returns `IR::ModuleConstant` when:

- `init.type` is `StringLiteral`, `NumericLiteral`, `BooleanLiteral`, `NullLiteral` — direct literal.
- `init.type` is `TemplateLiteral` with no interpolations — same as cva's `extract_cva_string`.
- `init.type` is `ArrayExpression` where **every** element passes the same check recursively, OR is a `SpreadElement` referencing a known-imported binding (defer to the verbatim fallback if any element fails).
- `init.type` is `ObjectExpression` where every property key is `Identifier` / `StringLiteral`, and every value passes recursively. Computed keys + spread bail to fallback.
- `init.type` is `TSAsExpression` / `TSSatisfiesExpression` — recurse on the inner expression. Drop the TS annotation; Ruby has no equivalent.
- `init.type` is `UnaryExpression` with a single `-` operator and a numeric operand — e.g., `const X = -1`.

Anything else (`CallExpression`, `MemberExpression`, identifier-referencing arrays/objects) bails to the existing `LocalBinding` path → existing module-bindings TODO block.

### IR

New value type next to `IR::CvaBinding`:

```ruby
# A literal-shaped module-level const that lowers to a real Ruby constant.
# Distinct from LocalBinding (which is captured verbatim as a TODO block)
# and CvaBinding (which has structured variants/defaults). Use sites that
# reference this binding's name are unaffected — the imported_names plumbing
# in build_translator already bails on the bare reference; the constant
# value just lives above the class.
#
# name           : String — original JS identifier (e.g. "TAGS", "COLUMNS").
# constant_name  : String — the Ruby constant identifier
#                  (`AST::Inflector.underscore(name).upcase`). Stored on the
#                  IR so the backend doesn't recompute and so future
#                  collision-detection has somewhere to bind.
# value          : Object — the Ruby-side value as a literal-friendly
#                  Ruby object (String, Integer, Float, true, false, nil,
#                  Array of these, Hash with String keys of these). Backends
#                  call `.inspect.freeze` to emit.
IR::ModuleConstant = Data.define(:name, :constant_name, :value)
```

### Phlex emission

Extend `render_module_bindings_prefix` (`backend/phlex.rb:271`) to partition module bindings three ways: `CvaBinding`, `ModuleConstant`, other.

`render_module_constants(bindings)` emits a block parallel to `render_cva_constants`:

```ruby
TAGS = { "warn" => "...", "error" => "..." }.freeze
DEFAULT_LIMIT = 50
```

The block sits above the class. Use-site references already bail to `nil` at runtime via the existing imported_names plumbing — that stays the same; future work can promote bucket-4 refs to the new constant when names match, but that's out of scope for slice A (it'd duplicate the A1 conditional-promotion work in attribute-value context).

### Files

| Path | Status | Scope |
|---|---|---|
| `lib/jsx_rosetta/ir/types.rb` | modify | Add `IR::ModuleConstant`. |
| `lib/jsx_rosetta/ir/lowering.rb` | modify | New `parse_module_constant(init, name)` mirroring `parse_cva_binding`. Plumb into `record_module_binding`. |
| `lib/jsx_rosetta/backend/phlex.rb` | modify | New `render_module_constants` helper. Three-way partition in `render_module_bindings_prefix`. |

### Specs

| Path | Status | Coverage |
|---|---|---|
| `spec/ir/lowering_spec.rb` | modify | Each literal shape (string, number, bool, null, array-of-literals, hash-of-literals, template-literal, TS-cast wrapper, unary minus). Non-literal initializers still produce LocalBinding. |
| `spec/backend/phlex_spec.rb` | modify | Emitted Ruby constants land above the class with the correct name + value. Use sites still emit the existing nil-bail behavior (so the cohabitation is verified). |

## A3 — `router.push` hint in non-handler bodies

### Detection

After lowering, hooks are captured as `IR::ReactHookCall(source: <verbatim JS>, library: :next_js | :react | …)`. For each call whose source contains a `router.push("…")` or `router.push(\`…\`)` invocation:

1. Parse the JS argument with `PagesRouting::HrefRewriter.parse_template_source` / literal-extract helpers — *not* with a new parser; reuse the slice-3 helper that already classifies literal vs. template-with-holes vs. unrewritable.
2. If `@href_rewriter` is set AND the parsed shape matches a route, prepend a hint line above the existing hook TODO block:

```
# → redirect_to claim_path(id) (translated from router.push)
```

3. If no `@href_rewriter` is set (no route table), still detect the pattern but emit just the descriptive hint:

```
# → consider redirect_to <helper> (translated from router.push)
```

4. Multiple `router.push` sites in the same hook block produce multiple hint lines.

### Why scope to hook bodies

`useEffect(() => router.push(...))` is the canonical redirect pattern in Next.js — that's where this fires. Event-handler bodies (extracted to `IR::EventHandler` / `IR::StimulusMethod` body sources) stay verbatim per the project rule against speculative JS-to-Ruby translation. Module-level `if (!user) router.push("/login")` would land in `LocalBinding.source` if it ever appeared at module top-level — out of scope for slice A; the hook-only target covers the realistic cases.

### Files

| Path | Status | Scope |
|---|---|---|
| `lib/jsx_rosetta/backend/phlex.rb` | modify | New `router_push_hint_lines(hook_source)` helper. Inject at the top of `hook_todo_block_lines`. |
| `lib/jsx_rosetta/pages_routing.rb` | (possibly) | Expose a `match_path(path_string) → "<helper>(<args>)"` shortcut alongside `HrefRewriter`. Avoid duplicating the parsing logic. |

### Specs

| Path | Status | Coverage |
|---|---|---|
| `spec/backend/phlex_spec.rb` | modify | `useEffect(() => router.push("/x"))` with route table emits the helper hint; without route table emits the generic hint. Event handler with `router.push` stays unannotated (no hint above stimulus method TODO). |

## Sequencing within slice A

A2 → A1 → A3. Reasoning:

- A2 is the largest TODO-reduction (~402 affected blocks) but the most mechanical — new IR type, new detector, new emitter. Land first to derisk.
- A1 changes the translator's behavior in a load-bearing way (render decisions). Land second so any regressions are visible against the now-cleaner A2 baseline.
- A3 is the smallest scope and depends only on existing plumbing. Land last.

Each lands as its own commit; the umbrella `Verify Slice A` step at the end runs the full rake + stress suite before patch-level release.

## Verification

```bash
bundle exec rake                           # rspec + rubocop
bash tmp/run_phlex_stress.sh                # full corpus translate
# compare tmp/stress/phlex_results.tsv vs. baseline (v0.5.1 stress numbers)
ruby -c tmp/stress/phlex_out/**/*.rb 2>&1 | grep -v "Syntax OK" | head
```

Headline metrics to compare:

- Clean-translation count (currently 895/929).
- Total TODO count (currently ~3.9/file mean across the corpus).
- Per-category TODO frequency for `translate condition`, `render guard`, `module-level constants`.
- `ruby -c` pass count (currently 1239/1239).

## Risks

- **A1 false positives.** Promoting `loading` to `@loading` assumes the user adds the prop; if they don't, render-time NameError. Mitigation: the TODO line names the promoted binding explicitly, so a code review catches it. Existing behavior emits dead `if false` branches that are *also* wrong — A1 trades silent dead code for a NameError with a TODO that points at the fix.
- **A2 constant-name collisions.** Two siblings in the same file with `const TAGS = …` would emit two `TAGS = …` lines. Lowering already captures module bindings once per program via `lower_all` (each sibling sees the same array by reference), so the existing module-bindings TODO doesn't collide — same property applies here. Spec covers the multi-component-per-file case.
- **A3 false negatives.** A `router.push` argument we can't classify (`router.push(buildUrl(x))`) silently emits no hint. Acceptable: the existing hook TODO still surfaces the source verbatim; the hint is purely additive.
- **A2 mutation hazard.** `.freeze` on a hash literal protects the hash, not its values. If a value is itself a mutable array, callers can still mutate the inner array. Not a translation-correctness risk; a Ruby idiom hint at most. Skip deep-freeze.
