# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

The README has the user-facing pipeline overview, backend trade-offs, and CLI surface. This file covers the things that aren't obvious from the README or a cold read of the source.

## Common commands

```bash
bin/setup                                                # bundle install + npm install in node/ (required after fresh clone)
bundle exec rspec                                        # full test suite
bundle exec rspec spec/backend/phlex_spec.rb             # single file
bundle exec rspec spec/backend/phlex_spec.rb:123         # single example by line
bundle exec rspec -e "guard-ladder"                      # examples whose describe/it matches
bundle exec rubocop
bundle exec rake                                         # default: rspec + rubocop
bundle exec exe/jsx_rosetta translate path/X.tsx --as=phlex --phlex-suffix=Component -o /tmp
```

`bin/setup` is the first-run requirement — the Node sidecar's `node_modules` isn't bundled, and `JsxRosetta.parse` shells out to `node/parse.js`. If `rspec` fails with parser errors, re-run `bin/setup`. `JSX_ROSETTA_NODE` overrides the `node` binary path.

`tmp/run_phlex_stress.sh` translates a large external JSX/TSX corpus through the Phlex backend; results land in `tmp/stress/` (gitignored). Use after non-trivial changes to confirm clean-translation count and `ruby -c` pass count don't regress. The TSV at `tmp/stress/phlex_results.tsv` is the headline.

## Pipeline

JSX → Babel AST → IR → backend. See README for the user-facing diagram. Hot files:

- `lib/jsx_rosetta/ir/lowering.rb` (1700+ lines, single class) — the source of truth for AST→IR. New translation behaviors land here.
- `lib/jsx_rosetta/ir/types.rb` — `Data.define`'d value classes. `IR::Component` is the root.
- `lib/jsx_rosetta/backend/view_component/expression_translator.rb` — shared by every backend for JS-expression fragments inside JSX bodies/attributes. Despite the directory name, the Phlex backend uses it too.
- `lib/jsx_rosetta/backend/phlex.rb` — the most actively maintained backend; most recent improvements target it first.

When in doubt, lowering preserves verbatim JS as `IR::Interpolation` so the backend's `ExpressionTranslator` can take a second pass at it.

## ExpressionTranslator identifier resolution (load-bearing)

An identifier reference inside JSX is classified into one of five buckets in order. This is the central machinery for closing render-time NameErrors — most recent fixes work by tightening which names land in bucket 4.

1. **Local scope** (pushed via `with_locals` — loop bindings, render-prop params, render-method params) → bare snake_case.
2. **Prop alias** (`"data-testid": dataTestId` in destructure) → `@ivar` of the underlying prop name.
3. **Prop name** → `@snake_case_ivar`.
4. **`local_binding_names` ∪ `imported_names`** (hook tuple destructures, top-level `const`/`function`/`import` declarations) → `nil` at leaf position; **bail** (return nil from the translate call) at member-chain root / unary operand / binary operand. The bail routes the caller into a TODO emission instead of a bare snake_case ref that NameErrors at render.
5. **Fallthrough** → bare snake_case identifier, recorded as `unresolved`. Backends drop with TODO on uppercase (PascalCase / SCREAMING) since those are almost always imports; lowercase passes through as a Rails-helper-shaped reference (`current_user` etc).

When adding a "we know X exists but can't translate it" class, plumb the names into the translator via `imported_names:` or `local_binding_names:` so bucket 4 fires.

## Project conventions

- **Preserve-as-TODO over speculative translation.** Flag `# TODO:` with verbatim source rather than guess. Translator bailout + backend drop-with-TODO helpers exist to keep this safe.
- **No JS-to-Ruby translation paths that best-guess arbitrary call expressions.** Extending the `ExpressionTranslator` for unambiguous mappings (`===`→`==`, `??`→`||`, etc.) is fine; guessing call semantics is not.
- **No external-corpus references in committed artifacts.** Specs, fixtures, source comments, commit messages, CHANGELOG, README must stay generic ("the stress corpus" / "a real-world JSX corpus"). Anything under `tmp/` is gitignored and can reference whatever.

## Emission rules that are subtle

- **Phlex attribute casing.** HTML-element attrs (lowercase tag) preserve camelCase verbatim — Phlex 2 only converts `_` to `-`, so SVG attrs like `preserveAspectRatio` and `viewBox` must stay camelCase. Component invocations (PascalCase tag) full-snake_case all keys per Ruby kwarg convention. See `plain_attribute_part` in `backend/phlex.rb`.
- **Dropped attributes are omitted, not nilled.** When a value bails to `nil` with a recorded TODO, the entire kwarg drops from the emission (the TODO above the element is the record). Explicit `attr={null}` in source still emits `attr: nil` (translation succeeded, no TODO → not a drop). Mechanism: `plain_attribute_part` watches whether a TODO was appended during value computation.
- **Sibling components share `module_bindings` by reference.** `lower_all` attaches the *same* array to every sibling, so backends emit the constants TODO prefix only on the first sibling via `first_emit_for_module_bindings?` (object-identity check on the array).
- **JSX in non-child positions** lowers through `lower_value_expression` → `lower_jsx_value`. Single-child Fragments unwrap (common React workaround for "single ReactNode required"). Hit by attribute values (`icon={<Foo/>}`) and render lambdas in column-config arrays.
- **Inline arrow handlers split by tag case.** On PascalCase tags, lower to `IR::EventHandler` (verbatim JS body) → backend extracts a stub instance method (`handle_click`, `handle_change`) and emits `on_click: method(:handle_click)`. On HTML elements, lower to Stimulus method extraction instead (see `stimulus_methods` on `IR::Component`).

## Spec gotchas

- `spec/backend/phlex_spec.rb` is the canonical large suite (~1000 lines now) — most behavior changes get their regression cover here.
- The Phlex spec helper's `files_for` uses **no suffix by default** — paths are `x.rb` (not `x_component.rb`) unless the spec passes `suffix: "Component"`.
- `spec/fixtures/jsx/*.{jsx,tsx}` + `spec/fixtures/expected/*` feed the Button full-IR-equality test; touch carefully.
- `spec/.rspec_status` is gitignored and huge — don't read it.

## Commit message style

Recent commits use a focused subject + structured body (subject explains *what changed*, body has sections like "Bug fixes:", "Implementation:", "Stress corpus impact:"). When behavior changes shift the stress numbers (clean translations / syntax fails / top dropped-attribute categories), include before/after counts in the body — they're the most useful signal for whether the change earns its complexity.
