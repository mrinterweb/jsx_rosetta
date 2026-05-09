# jsx_rosetta

Translate React/JSX components into Rails [ViewComponent](https://viewcomponent.org/)
classes paired with ERB templates.

`jsx_rosetta` parses JSX (and TSX) via Babel running in a Node sidecar, lowers
the parsed AST into a framework-agnostic semantic IR, and emits target output
through pluggable backends. The initial backend produces a `.rb` ViewComponent
class plus a `.html.erb` template; the IR is designed so additional backends
(Phlex, Slim, Phoenix LiveView, …) can be added without changing the frontend.

```
JSX text ──► Babel AST ──► Ruby AST ──► IR ──► ViewComponent backend ──► .rb + .html.erb
            (Node + Babel) (typed tree)  (sema)  (string-built ERB + Ruby)
```

## Installation

```bash
bundle add jsx_rosetta
bundle exec jsx_rosetta install   # installs the gem's Node sidecar dependencies
```

Requires:
- Ruby ≥ 3.2
- Node.js ≥ 18 (used in a subprocess for parsing)

The Node sidecar's `node_modules` is **not** bundled in the gem — `jsx_rosetta install`
runs `npm install` in the gem's vendored `node/` directory. Set
`JSX_ROSETTA_NODE` if the `node` executable is in a non-standard location.

## CLI

```bash
jsx_rosetta translate path/to/Button.jsx -o app/components
# wrote app/components/button_component.rb
# wrote app/components/button_component.html.erb

jsx_rosetta parse path/to/Button.jsx > button.ast.json
jsx_rosetta install
jsx_rosetta version
```

`.tsx` files are auto-detected; pass `--tsx` to force TypeScript parsing on a
`.jsx` file.

## Library API

```ruby
require "jsx_rosetta"

source = File.read("Button.jsx")

# Just the parsed AST (Babel-shaped, typed Ruby objects).
ast = JsxRosetta.parse(source)
ast.walk.find { |n| n.is_a?(JsxRosetta::AST::JSXElement) }.tag_name
# => "button"

# Lowered IR (semantic, backend-agnostic).
ir = JsxRosetta.lower(source)
ir.props.map(&:name)
# => ["children", "onClick", "variant"]

# End-to-end translation. Returns an array of File value objects.
files = JsxRosetta.translate(source, backend: :view_component)
files.first.path     # => "button_component.rb"
files.first.contents # => "# frozen_string_literal: true\n…"
```

### What translates today

| JSX construct                        | Translation                                                |
| ------------------------------------ | ---------------------------------------------------------- |
| `<button type="x">`                  | Literal HTML attribute                                     |
| `<a href={url}>`                     | `href="<%= @url %>"` (when `url` is a prop)                |
| `className={`btn-${variant}`}`       | `class="btn-<%= @variant %>"` (template literal inlined)   |
| `<Button variant="primary" />`       | `<%= render ButtonComponent.new(variant: "primary") %>`    |
| `{children}` (when prop)             | `<%= content %>` (ViewComponent default slot)              |
| `{cond && <X />}`, `{cond ? X : Y}`  | `<% if %>…<% end %>` / with `<% else %>` branch            |
| `{items.map((item, i) => <X />)}`    | `<% @items.each do \|item, i\| %>…<% end %>`                |
| `onClick={handler}`                  | `data-action="<%= @handler %>"` (Stimulus action descriptor)|
| Default values (`x = "primary"`)     | Translated when literal/identifier; flagged otherwise      |
| Bare prop identifiers                | `@snake_case_name`                                         |
| `item.label` inside a loop           | `item.label` (loop binding stays local)                    |

Anything the translator can't handle is emitted with a `<%# TODO %>` marker
plus the verbatim JS source so the human reviewer can fix it.

### What's deferred

- React `useState`/`useEffect` — no introspection of component-internal state yet.
- React data fetching, `react-query`, Suspense, `useContext`.
- React Router.
- Arbitrary JS expression translation (function calls, conditionals, subscripts).
  Simple shapes (identifiers, literals, simple template literals, member chains)
  are translated; everything else is flagged.
- A Stimulus controller runtime (the gem emits `data-action="…"` references but
  doesn't generate `*_controller.js` files yet).
- Backends other than ViewComponent (Phlex, Slim, LiveView).

See `PLAN.md` for the phased roadmap.

## Architecture

```
lib/jsx_rosetta/
  parser.rb              # public entry: JSX text → AST::Program
  node_bridge.rb         # subprocess plumbing for the Node sidecar
  ast/                   # typed Ruby classes mirroring Babel node shapes
  ir/                    # semantic, framework-agnostic intermediate representation
    lowering.rb          # AST → IR
  backend/
    base.rb              # backend interface
    view_component.rb    # IR → { ruby:, erb: }
  cli.rb                 # `exe/jsx_rosetta` dispatch
node/
  parse.js               # stdin (JSX request) → stdout (Babel JSON AST)
  package.json           # @babel/parser dependency
```

## Development

```bash
bin/setup          # bundle install + npm install in node/
bundle exec rspec  # run the full test suite
bundle exec rubocop
```

Fixtures used by the golden-file tests live in `spec/fixtures/`:
- `spec/fixtures/jsx/*.{jsx,tsx}` — input JSX
- `spec/fixtures/expected/*` — hand-written expected output

## License

MIT.
