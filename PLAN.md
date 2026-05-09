# jsx_rosetta — Implementation Plan

`jsx_rosetta` is a Ruby gem that translates JSX into Rails ViewComponent
(Ruby class + ERB template) via a three-stage pipeline. Other output
formats (Phlex, Slim, Phoenix LiveView, etc.) are anticipated by design
and accommodated by the IR — adding one is a new backend, not a rewrite.

## Pipeline

```
JSX text ──► Babel AST ──► Ruby AST ──► IR ──► ViewComponent backend ──► .rb + .html.erb
            (Node + Babel) (Ruby tree)  (sema)  (string-built ERB + Ruby)
```

## Architectural decisions (locked)

- **JSX parsing:** Shell out to a Node sidecar running `@babel/parser`.
  No native JS engine in the Ruby process.
- **Node dependencies:** Not vendored. `node/package.json` declares deps;
  `node/node_modules/` is gitignored. The gem provides an install
  command (`jsx_rosetta install`) that runs `npm install` for the user.
- **AST:** Typed Ruby classes mirroring Babel node shapes 1:1. The gem
  does not normalize at the AST layer — that's the IR's job.
- **IR:** Required. Framework-agnostic, semantic. The multi-backend
  abstraction lives here. Nothing in the IR mentions Ruby, ERB, or Rails.
- **Initial backend:** ViewComponent (one `.rb` class + one `.html.erb`
  per JSX component).
- **ERB writer:** String-built in Ruby. Optional structural validation
  via the `herb` gem in tests. Migrate to programmatic Herb construction
  only if string-building causes real pain.
- **No RBS.** Skeleton `sig/` directory removed.
- **Fixtures:** `spec/fixtures/jsx/` for JSX inputs,
  `spec/fixtures/expected/` for golden output files.

## Project layout

```
lib/jsx_rosetta/
  version.rb
  parser.rb              # public entry: JSX text → AST::Program
  node_bridge.rb         # subprocess plumbing
  parse_error.rb
  ast/
    node.rb              # base, with deconstruct_keys for pattern matching
    builder.rb           # JSON hash → typed nodes
    visitor.rb
    <one-per-type>.rb
  ir/
    node.rb
    lowering.rb          # AST::Program → IR::Component
    <one-per-type>.rb
  backend/
    base.rb              # backend interface; pluggable
    view_component.rb    # IR::Component → { ruby:, erb: }
  cli.rb                 # exe/jsx_rosetta dispatch
node/
  package.json
  parse.js               # stdin (JSX) → stdout (JSON AST)
  .gitignore             # node_modules/
spec/
  parser_spec.rb
  ast/{builder,visitor}_spec.rb
  ir/lowering_spec.rb
  backend/view_component_spec.rb
  fixtures/
    jsx/{button,dialog,combobox}.{jsx,tsx}
    expected/{button,dialog,combobox}.{rb,html.erb}
exe/jsx_rosetta
```

## Components

### Node sidecar (`node/`)

- `package.json` — declares `@babel/parser` as the only runtime dep.
- `parse.js` — reads a JSON request from stdin (`{ source, typescript,
  source_filename }`), runs `@babel/parser`, writes a JSON response to
  stdout. Errors surface as `{ error: { message, line, column } }`.
- `node_modules/` — gitignored. Users install via `jsx_rosetta install`.

### Parser (`lib/jsx_rosetta/parser.rb`)

```ruby
JsxRosetta::Parser.new.parse(source, typescript: false) # => AST::Program
```

- Locates `node` on `PATH`, with `JSX_ROSETTA_NODE` env override.
- Spawns the sidecar via `Open3.capture3` (one-shot mode for MVP).
- Parses the JSON response and hands it to `AST::Builder`.
- A long-lived worker (newline-delimited base64-framed requests) is a
  Phase 6 optimization, not a Phase 0 concern.

### AST (`lib/jsx_rosetta/ast/`)

- `Node` base — `type`, `loc`, `range`, `children`, `deconstruct_keys`.
- Typed subclasses for each Babel node type the corpus actually uses.
  Start narrow; expand as fixtures demand. Unknown types fall through to
  a generic `Node` so we don't crash on ESNext additions.
- `Builder.build(json_hash) → Node` — factory dispatching on `type`,
  recursing into children.
- `Visitor` — `visit(node)` dispatches to `visit_<TypeName>`,
  default-recurses children.

### IR (`lib/jsx_rosetta/ir/`)

Initial node types (expanded by phase as fixtures require):

```
Component       { name, props[], slots[], body }
Element         { tag, attributes[], children[] }
Text            { value }
Interpolation   { expression }              # opaque token, emitted verbatim
Loop            { iterable, item, index?, body }
Conditional     { test, consequent, alternate? }
ComponentInvocation { name, props[], children[] }
Fragment        { children[] }
Attribute       { name, value }             # literal or Interpolation
EventBinding    { event, handler }          # onClick, onChange — backend decides
Slot            { name }                    # children prop or named slot
StyleBinding    { classes[], conditional[] } # className={cn(...)} lowered here
```

`Lowering.lower(ast_program) → IR::Component` is the AST→IR pass. It
normalizes JSX-specific patterns: the three "render-if" forms
(`{cond && x}`, `{cond ? x : null}`, `{cond ? x : y}`) all collapse to
one `Conditional`. JS expressions stay as opaque tokens during MVP —
they're emitted verbatim into ERB and flagged with a comment when
non-trivial.

### Backend (`lib/jsx_rosetta/backend/`)

- `Base` — interface every backend implements:
  ```ruby
  Backend::Base.new.emit(ir_component) # => { files: [{ path:, contents: }, ...] }
  ```
  Pluggable from day one so adding Phlex/Slim/LiveView later is mechanical.
- `ViewComponent` — string-builds the `.rb` class and `.html.erb`
  template. Optional: parse the emitted ERB with the `herb` gem in
  tests as a structural sanity check.

### CLI (`exe/jsx_rosetta`)

- `jsx_rosetta install` — runs `npm install` in the gem's vendored
  `node/` directory.
- `jsx_rosetta translate input.jsx --backend=view_component --out dir/` —
  end-to-end translation.
- `jsx_rosetta parse input.jsx` — emit the parsed AST as JSON. Useful
  for debugging fixtures.

## Phases

### Phase 0 — Node sidecar + Ruby round-trip

- Scaffold `node/` with `package.json`, install `@babel/parser`,
  gitignore `node_modules`.
- Write `node/parse.js` (one-shot mode).
- `JsxRosetta::Parser#parse` calls the sidecar, returns the parsed
  JSON as a nested Hash (no typed nodes yet).
- Drop `spec/fixtures/jsx/button.jsx`.
- Specs: parser returns a Program containing the expected JSXElement;
  `ParseError` surfaces line/column on invalid JSX.
- Strip the gemspec's TODO placeholders; delete `sig/`.

### Phase 1 — Typed AST + visitor

- `AST::Node` base + Babel node subtypes Button uses.
- `AST::Builder` factory; pattern-match support on nodes.
- `AST::Visitor` with default recursion. Spec: visitor collects every
  JSXElement tag from Button.

### Phase 2 — IR + lowering for Button

- IR node types Button needs (`Component`, `Element`, `Attribute`,
  `Interpolation`, `StyleBinding`, `ComponentInvocation`).
- `Lowering` pass producing IR from AST for Button.
- Spec: parsing Button JSX yields the expected IR tree.

### Phase 3 — ViewComponent backend, end-to-end Button

- `Backend::Base` interface.
- `Backend::ViewComponent` for the Button IR subset.
- Hand-write `spec/fixtures/expected/button.rb` and `button.html.erb`.
- Golden-file test: `JsxRosetta.translate(button.jsx)` matches the
  expected files. **First end-to-end vertical slice.**

### Phase 4 — Dialog: state, events, slots

- IR additions: `EventBinding`, `Slot`, `Conditional`. Lowering for
  compound components.
- ViewComponent backend learns slots, derived state (lowered to
  component methods), Stimulus `data-action` / `data-controller` /
  `data-target` attributes for events and refs.
- Decide where the Stimulus runtime lives (likely a sibling JS package,
  out of this gem's scope but referenced by the README).

### Phase 5 — Combobox: keyboard nav + list rendering

- IR addition: `Loop`. Lowering for `.map(...)` patterns.
- More Stimulus controller surface (combobox, keyboard-nav, focus-trap).

### Phase 6 — DX polish

- `jsx_rosetta install` CLI command and helpful "Node missing /
  `@babel/parser` not installed — run `bundle exec jsx_rosetta install`"
  errors.
- Long-lived Node worker (newline-delimited base64-framed JSON) when
  parsing many files matters.
- README rewrite. `bin/setup` runs `npm install` in `node/`.
- Optional: structural validation of emitter output via the `herb` gem.

## Deferred questions

1. **Stimulus runtime packaging** — same repo, sibling gem, or JS
   package? Decide before Phase 4.
2. **CVA / tailwind-variants** — for MVP, pass `cn(...)` through as a
   flagged interpolation. Build-time evaluation can come later.
3. **Worker framing protocol** — only matters when batch parsing matters
   (Phase 6).
4. **Migrating ERB emission to Herb** — only if string-built ERB causes
   real pain.

## Non-goals

- Translating arbitrary React codebases. The MVP is component-library-shaped input.
- Translating React data-fetching (`react-query`, SWR, Suspense). Flag for manual review.
- Translating React Router. Out of scope.
- Runtime JS-to-Ruby translation of arbitrary expressions. Pass through and surface for human review.
- Round-tripping (ERB → JSX). One direction only.
- Perfect visual parity. Structural and behavioral parity is the bar; visual tweaks may be needed.
