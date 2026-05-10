# jsx_rosetta

Translate React/JSX components into Rails 8.1 [ViewComponent](https://viewcomponent.org/)
classes (or plain Rails view templates) — and lift React Router config into a
runnable `rails generate controller` script.

`jsx_rosetta` parses JSX/TSX via Babel running in a Node sidecar, lowers the
parsed AST into a framework-agnostic semantic intermediate representation (IR), and emits target output
through pluggable backends. The pipeline is end-to-end working: a real React
app's components and routes can be translated, dropped into a fresh Rails 8.1
app, and rendered with only a handful of human edits at the TODO markers the
gem itself emits.

```
JSX text ──► Babel AST ──► Ruby AST ──► IR ──► backend ──► .rb / .html.erb / _controller.js
            (Node sidecar) (typed tree) (sema)        (ViewComponent / RailsView / RoutesScript)
```

## Installation

```bash
bundle add jsx_rosetta
bundle exec jsx_rosetta install   # npm-installs the gem's Node sidecar deps
```

Requires:
- Ruby ≥ 3.2
- Node.js ≥ 18 (subprocess used for parsing)

The sidecar's `node_modules` is **not** bundled in the gem — `jsx_rosetta install`
runs `npm install` in the gem's vendored `node/` directory. Set
`JSX_ROSETTA_NODE` if `node` is in a non-standard location.

## CLI

```bash
# Translate a JSX/TSX component into a ViewComponent (sidecar layout, default)
jsx_rosetta translate path/to/Button.tsx -o app/components
# →   app/components/button_component.rb
#     app/components/button_component/button_component.html.erb
#     app/components/button_component/button_controller.js   (when inline arrow handlers)

# Translate a route-tied page as a Rails view template (no Ruby class)
jsx_rosetta translate path/to/Home.tsx --as=view -o app/views/home
# →   app/views/home/home.html.erb       (rename to index.html.erb)

# Extract <Routes><Route> entries into a runnable Ruby script
jsx_rosetta routes path/to/router.tsx -o tmp/generate_controllers.rb
# Review the script. Uncomment the system() calls you want, then:
ruby tmp/generate_controllers.rb

# Inspect the parsed Babel AST
jsx_rosetta parse path/to/Button.tsx > button.ast.json

# Install the Node sidecar deps
jsx_rosetta install

jsx_rosetta version
```

`.tsx` files are auto-detected from the extension; pass `--tsx` to force
TypeScript parsing on a `.jsx`-named file.

## Library API

```ruby
require "jsx_rosetta"

source = File.read("Button.tsx")

# Just the parsed AST (Babel-shaped, typed Ruby objects)
ast = JsxRosetta.parse(source)
ast.walk.find { |n| n.is_a?(JsxRosetta::AST::JSXElement) }.tag_name
# => "button"

# Lowered IR (semantic, backend-agnostic). Returns the first component.
ir = JsxRosetta.lower(source)
ir.props.map(&:name)        # => ["children", "onClick", "variant"]
ir.stimulus_methods         # event handlers extracted to Stimulus
ir.react_hooks              # useState/useEffect/etc. flagged for the human

# All components in a multi-component file
JsxRosetta::IR.lower_all(JsxRosetta.parse(source), source: source)

# End-to-end translation. Returns an array of File value objects.
files = JsxRosetta.translate(source)
files.first.path     # => "button_component.rb"
files.first.contents # => "# frozen_string_literal: true\n…"

# Same source as a plain Rails view (no .rb class, no sidecar dir)
JsxRosetta.translate(source, backend: :rails_view)

# Extract React Router routes
route_tree = JsxRosetta::Routes.lower(JsxRosetta.parse(File.read("router.tsx")))
JsxRosetta::Backend::RoutesScript.new(source_path: "router.tsx").emit(route_tree)
```

Optional kwargs to `JsxRosetta.translate`:
- `backend: :view_component | :rails_view` (default `:view_component`)
- `helpers: nil | Hash | false` — JSX-name → Rails-helper mapping (see below)
- `layout: :sidecar | :flat` (default `:sidecar`, ignored for `:rails_view`)
- `typescript: true` — force the TypeScript Babel plugin
- `source_filename:` — surfaces in parse errors

## What translates

| JSX construct                        | Translation                                                |
| ------------------------------------ | ---------------------------------------------------------- |
| Function & arrow components          | `class XComponent < ::ViewComponent::Base`                 |
| Multi-component files                | One `.rb` + `.html.erb` pair per exported component        |
| `<button type="x">`                  | Literal HTML attribute                                     |
| `<a href={url}>`                     | `href="<%= @url %>"` when `url` is a prop                  |
| `<a href={`/p/${slug}`}>`            | `href="/p/<%= @slug %>"` (template literal inlined)        |
| `<a aria-label={x}>`                 | `aria-label="<%= @x %>"` on Element; `"aria-label" => @x` on Component |
| `<button type="button" {...rest}>`   | `<%= tag.button(type: "button", **@rest) do %>…<% end %>`  |
| `<Button variant="primary" />`       | `<%= render ButtonComponent.new(variant: "primary") %>`    |
| `<Tabs.List>`                        | `<%= render Tabs::ListComponent.new(...) %>`               |
| `<Link href="/x">`                   | `<%= link_to("/x") do %>…<% end %>` (default helper map)   |
| `<Image src="..." />`                | `<%= image_tag("...", alt: "...") %>` (default helper map) |
| `{children}` (when prop)             | `<%= content %>` (ViewComponent default slot)              |
| `{cond && <X />}`, `{cond ? X : Y}`  | `<% if %>…<% end %>` / with `<% else %>` branch            |
| `{items.map((item, i) => <X />)}`    | `<% @items.each do \|item, i\| %>…<% end %>`               |
| `{post.coverImage}`                  | `@post.cover_image` (member chains snake-cased)            |
| `{!preview}`                         | `!@preview` (unary negation)                               |
| `className={cn("a", b, { c: cond })}`| `class="a <%= @b %> <%= @cond ? "c" : '' %>"`              |
| `style={{ fontSize: 12 }}`           | `style="font-size: 12;"` (kebab-case keys)                 |
| `{/* foo */}`                        | `<%# foo %>`                                               |
| `{"foo"}`, `{42}`                    | Plain text (`<%= " " %>` clutter eliminated)               |
| `{true}`, `{null}`                   | Dropped (matches React runtime)                            |
| `<hr />`, `<img />`                  | Self-closing void elements                                 |
| `onClick={handler}` (handler is prop)| `data-action="<%= @handler %>"` (Stimulus action descriptor) |
| `onClick={() => …}` (inline)         | Stimulus controller method + `data-action="click->name#methodName"` |
| `const Comp = asChild ? X : "tag"`   | Synthesized `<% if @as_child %>…<% else %>…<% end %>`      |
| Default values (`x = "primary"`)     | Translated when literal/identifier/member-chain            |
| Bare prop identifiers                | `@snake_case_name`                                         |

## What's flagged for human review

The gem emits a `<%# TODO: … %>` comment whenever a translation isn't safe to
auto-perform. Common cases:

- **React hooks** (`useState`, `useEffect`, `useRef`, …) → distinct comment
  block at the top of the template, with the Hotwire/Stimulus alternative
  noted and the original JS preserved verbatim.
- **Local non-JSX `const` bindings** (`const date = parseISO(s)`) → comment
  block at the top with the original JS preserved.
- **Unrecognized JS expressions** (function calls, subscripts, complex
  ternaries) → inline TODO with verbatim source.
- **Unresolved identifiers** (imports like `EXAMPLE_PATH`, `CMS_NAME`) →
  inline TODO listing the offending names so the human can wire them up.
- **`dangerouslySetInnerHTML` and similar opaque attributes** → flagged.
- **Reserved Rails controller names** (in the routes script) → `# WARNING:`
  line listing collisions.

## What's deferred

- Translating React state primitives (`useState` / `useEffect` etc.). The
  policy is to flag and route behavior to Stimulus controllers, not to
  recreate React's runtime in Ruby.
- React Router's data-router form (`createBrowserRouter([...])`). Only the
  declarative `<Routes><Route>` shape is parsed today.
- Backends other than ViewComponent and RailsView (Phlex, Slim, LiveView).
- Suspense → Turbo Frame mapping (depends on a data-fetching translation
  story we don't have yet).

## ViewComponent emission targets

Two backends, picked via `--as` on the CLI or `backend:` in the API:

**`:view_component` (default)** — emits a sidecar layout matching
ViewComponent's `--sidecar` generator convention:

```
app/components/
  card_component.rb                              # at top level
  card_component/
    card_component.html.erb                      # sidecar template
    card_controller.js                           # Stimulus, when applicable
```

Pass `layout: :flat` to revert to the older flat layout
(`card_component.rb` + `card_component.html.erb` side-by-side).

**`:rails_view`** — for pages tied to a route. Emits one `.html.erb` with
no Ruby class and no sidecar. Place at `app/views/<controller>/<action>.html.erb`;
the controller's instance variables become the template's `@x` references.

## Helper mappings

Capitalized JSX tags that have a direct Rails helper analog skip the
`<%= render XComponent.new(...) %>` indirection. Defaults:

| JSX      | Emits                                          |
| -------- | ---------------------------------------------- |
| `<Link>` | `<%= link_to(href, **rest) do %>…<% end %>`    |
| `<Image>`| `<%= image_tag(src, alt:, **rest) %>`          |

Override:

```ruby
JsxRosetta.translate(source, helpers: {
  "Link"  => { method: :link_to,   positional: :href },
  "Image" => { method: :image_tag, positional: :src },
  "Btn"   => { method: :button_to, positional: :url }
})

# Disable entirely (everything stays as <%= render XComponent.new(...) %>)
JsxRosetta.translate(source, helpers: false)
```

## Stimulus integration

Inline arrow event handlers (and const-bound arrows referenced from
`onX={handler}`) extract to a generated `<snake>_controller.js` skeleton:

```jsx
function CopyButton({ text }) {
  const handleClick = () => navigator.clipboard.writeText(text);
  return <button onClick={handleClick}>Copy</button>;
}
```

emits three files:

```ruby
# copy_button_component.rb
class CopyButtonComponent < ::ViewComponent::Base
  def initialize(text:); @text = text; end
end
```

```erb
<%# copy_button_component/copy_button_component.html.erb %>
<button data-controller="copy-button"
        data-action="click->copy-button#handleClick">
  Copy
</button>
```

```javascript
// copy_button_component/copy_button_controller.js
import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  // TODO: translate from the original JSX handler:
  //   navigator.clipboard.writeText(text)
  handleClick(event) {
    // ...
  }
}
```

For Rails to find sidecar Stimulus controllers, add to
`config/importmap.rb`:

```ruby
pin_all_from "app/components", under: "components", preload: true
```

and to `app/javascript/application.js`:

```js
import { application } from "controllers/application"
import { eagerLoadControllersFrom } from "@hotwired/stimulus-loading"
eagerLoadControllersFrom("controllers", application)
eagerLoadControllersFrom("components", application)
```

## Routes subcommand

`jsx_rosetta routes router.tsx` parses `<Routes><Route>` JSX and emits a
runnable Ruby script:

- Lists each parsed `path → element` mapping.
- Suggests `system "rails", "generate", "controller", …` invocations
  (commented for review).
- Consolidates `/xs` + `/xs/:id` pairs into `resources :xs, only: %i[index show]`.
- Emits `match "*path", to: …, via: :all` for catch-all routes.
- Warns when a generated controller name collides with a reserved Rails term.
- Prints a suggested `config/routes.rb` block.

The script is meant to be reviewed and edited before `ruby`-running it.

## Architecture

```
lib/jsx_rosetta/
  parser.rb                                # JSX text → AST::File
  node_bridge.rb                           # subprocess plumbing
  ast/                                     # typed Ruby classes mirroring Babel
  ir/
    types.rb                               # IR value classes
    lowering.rb                            # AST → IR
  routes.rb                                # AST → IR::RouteTree (React Router)
  backend/
    base.rb
    view_component.rb                      # IR → .rb + .html.erb (+ _controller.js)
    view_component/expression_translator.rb
    rails_view.rb                          # IR → .html.erb only
    routes_script.rb                       # IR::RouteTree → reviewable Ruby script
  cli.rb                                   # exe/jsx_rosetta dispatch
node/
  parse.js                                 # stdin (JSX request) → stdout (Babel JSON AST)
  package.json                             # @babel/parser
```

The IR sits between parsing and emission so additional backends (Phlex,
Slim, LiveView, …) can be added without changing the frontend.

## Development

```bash
bin/setup          # bundle install + npm install in node/
bundle exec rspec  # run the full test suite
bundle exec rubocop
```

End-to-end fixtures live in `spec/fixtures/`:
- `spec/fixtures/jsx/*.{jsx,tsx}` — input JSX
- `spec/fixtures/expected/*` — hand-written expected output

For a worked example of dropping translated output into a real Rails 8.1 app,
see `CHANGELOG.md` — Phase 9 and Phase 9b describe the multi-route React
Router → Rails app demo end-to-end.

## License

MIT.
