# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Common commands

```bash
bin/setup                              # bundle install + npm install in node/
bundle exec rspec                      # full test suite
bundle exec rspec spec/backend/phlex_spec.rb           # single file
bundle exec rspec spec/backend/phlex_spec.rb:123       # single example by line
bundle exec rspec -e "guard-ladder"    # examples whose describe/it matches
bundle exec rubocop                    # lint (also runs as part of `rake`)
bundle exec rake                       # default: rspec + rubocop
bundle exec exe/jsx_rosetta translate path/to/X.tsx --as=phlex --phlex-suffix=Component -o /tmp
```

The Node sidecar (`node/parse.js`) does the JSX parsing via `@babel/parser`. If
`bundle exec rspec` fails with parser errors, re-run `bin/setup` to refresh
`node/node_modules`. `JSX_ROSETTA_NODE` overrides the `node` binary path.

### Stress test

`tmp/run_phlex_stress.sh` translates a large external JSX/TSX corpus through
the Phlex backend and writes results to `tmp/stress/`. It's gitignored. Use
after non-trivial changes to confirm clean-translation count and `ruby -c`
pass count don't regress. Numeric stress results live in `tmp/stress/phlex_results.tsv`.

## Architecture

Three-stage pipeline, IR is the pivot:

```
JSX text ──► Babel AST ──► IR ──► backend ──► .rb / .html.erb / _controller.js
            (Node sidecar) (sema)    (Phlex / ViewComponent / RailsView / RoutesScript)
```

- **Parser** (`lib/jsx_rosetta/parser.rb`, `node_bridge.rb`) — shells out to
  `node/parse.js` once per source; stdin = JSX text, stdout = Babel JSON.
  Wraps the JSON in typed `AST::*` nodes (`ast/types.rb`).
- **Lowering** (`lib/jsx_rosetta/ir/lowering.rb`) — single class, 1700+ lines,
  walks the Babel AST and produces an `IR::Component`. Major responsibilities:
  component discovery, prop destructuring, hook detection, module-binding +
  module-import capture, `cn()`/`clsx()` className decomposition, JSX
  recognition in non-child positions (attribute values, render lambdas).
  When in doubt, lowering preserves verbatim JS as `IR::Interpolation` so a
  backend's `ExpressionTranslator` can take a second pass.
- **IR types** (`lib/jsx_rosetta/ir/types.rb`) — Ruby `Data.define`'d value
  classes. `IR::Component` is the root; everything else hangs off it.
- **Backends** (`lib/jsx_rosetta/backend/*.rb`) — `Phlex`, `ViewComponent`,
  `RailsView`, and `RoutesScript`. Each takes an `IR::Component` and returns
  an array of `File` value objects. Backends share
  `backend/view_component/expression_translator.rb` for JS-expression
  fragments inside JSX bodies/attributes.

### ExpressionTranslator identifier resolution

In `lib/jsx_rosetta/backend/view_component/expression_translator.rb`, an
identifier reference is classified into one of these buckets in order:

1. **Local scope** (pushed via `with_locals` — loop bindings, render-prop
   params, render-method params) → bare snake_case.
2. **Prop alias** (`"data-testid": dataTestId` in destructure) → `@ivar` of
   the underlying prop name.
3. **Prop name** → `@snake_case_ivar`.
4. **`local_binding_names` ∪ `imported_names`** (hook tuple destructures,
   top-level `const`/`function`/`import` declarations) → `nil` at leaf
   position, **bail** (return nil) at member-chain root / unary operand /
   binary operand. The "bail" routes the caller into a TODO emission instead
   of producing a bare snake_case ref that NameErrors at render time.
5. **Fallthrough** → bare snake_case identifier, recorded as `unresolved` so
   the backend can decide whether to drop with TODO (uppercase imports) or
   pass through (Rails-helper-shaped lowercase names like `current_user`).

The bailout machinery (#4) is load-bearing — most "render-time NameError"
classes are closed by tightening which names are known-unresolvable.
When adding a new "we know X exists but can't translate it" class, plumb
the names into the translator via `imported_names:` or `local_binding_names:`.

### Conventions worth knowing

- **Preserve-as-TODO over speculative translation.** When a JS construct
  can't be translated procedurally, emit `# TODO: …` with the verbatim
  source rather than guessing. The translator's bailout paths and the
  backend's drop-with-TODO helpers exist to keep this safe across edge
  cases.
- **Phlex attribute casing.** HTML-element attributes (`tag` is lowercase)
  preserve camelCase verbatim — Phlex 2 only converts `_` to `-`, so SVG
  attrs like `preserveAspectRatio`, `viewBox` must stay camelCase. Component
  invocations (PascalCase tag) full-snake_case all keys per Ruby kwarg
  convention. See `plain_attribute_part` in `backend/phlex.rb`.
- **Dropped attributes are omitted, not nilled.** When an attribute value
  bails to `nil` with a recorded TODO, the entire kwarg is dropped from the
  emission (the TODO comment above the element is the record). Explicit
  `attr={null}` in source still emits `attr: nil` (no TODO → not a drop).
- **Sibling components share `module_bindings`.** A source file with
  multiple components has the SAME `module_bindings` array attached to each
  (passed by reference). Backends emit the constants TODO prefix only on
  the first sibling (see `first_emit_for_module_bindings?` in `backend/phlex.rb`).
- **JSX in non-child positions** lowers through `lower_value_expression` →
  `lower_jsx_value`. Single-child Fragments unwrap. Used by attribute
  values (`icon={<Foo/>}`), render lambdas (`render: (v) => <Tag>{v}</Tag>`).
- **Inline arrow handlers on PascalCase tags** lower to `IR::EventHandler`
  (verbatim body source); the Phlex backend extracts to a stub instance
  method (`handle_click`, `handle_change`, ...) and emits
  `on_click: method(:handle_click)` at the kwarg. Inline arrows on
  HTML elements take a different path: Stimulus controller method
  extraction (see `stimulus_methods` in IR::Component).

### Backends to know

| Backend | Emits | Notes |
|---|---|---|
| `:phlex` (recommended target) | Single `.rb` per component, optional `_controller.js` for Stimulus | Three naming strategies: bare / `suffix:` / `namespace:`. SVG-attribute-casing-aware. The bulk of recent work targets this backend. |
| `:view_component` | `.rb` + sidecar `.html.erb` (+ optional `_controller.js`) | `layout: :flat` reverts to side-by-side files. Some emission helpers lag the Phlex backend (e.g. weaker drop-with-TODO behavior in `tag_builder_value`). |
| `:rails_view` | `.html.erb` only, no class | For route-tied pages. |
| `:routes_script` | Runnable Ruby script | Reads `<Routes><Route>` JSX; emits `rails generate controller` invocations + a suggested `routes.rb`. |

### Specs and fixtures

- `spec/backend/phlex_spec.rb` is the canonical large suite (~700+ lines)
  and is where most behavior changes get their regression cover.
- `spec/ir/lowering_spec.rb` covers AST → IR mechanics.
- `spec/fixtures/jsx/*.{jsx,tsx}` + `spec/fixtures/expected/*` — used by
  the Button-fixture full-IR-equality test; touch carefully.
- The Phlex spec helper's `files_for` uses no suffix by default — paths are
  `x.rb` (not `x_component.rb`) unless the spec passes `suffix: "Component"`.
- `spec/.rspec_status` is gitignored and large — don't read it.

### Translation conventions in commit messages

Recent commits prefer a structured body: short subject, then sections like
"Bug fixes:", "Implementation:", "Stress corpus impact:". Stress numbers
(clean translations / syntax fails / before-after attribute drops) are
worth including when behavior changes shift those.

## Don't

- **Don't bump `version.rb` or write CHANGELOG release headers proactively.**
  The user decides when to cut a tag; just keep landing fixes on `main`.
  See the user's memory for current cadence preference.
- **Don't reference external corpora by name in committed code or docs.**
  Stress scripts under `tmp/` are gitignored and can reference whatever;
  specs, fixtures, source comments, commit messages, and CHANGELOG entries
  must stay generic ("the stress corpus" / "a real-world JSX corpus").
- **Don't add JS-to-Ruby translation paths that "best-guess" arbitrary JS.**
  The deliberate policy is to flag-as-TODO over speculative translation.
  Extending the `ExpressionTranslator` to cover new shapes is fine when
  the mapping is unambiguous (e.g. `===` → `==`, `??` → `||`); guessing at
  call expressions is not.
