# Changelog

## [Unreleased]

### Added — translator (lowering)

- **Arrow-function components** — `const X = () => …` (with implicit
  return or block body), and exported variants. Previously only
  `function X() { … }` was recognized.
- **Multi-component files** — `lower_all` walks the entire program body
  and returns one IR::Component per matched declaration. Backends emit
  one output pair per component.
- **Compound component tags** — `<Tabs.List>` lowers as a
  `ComponentInvocation(name: "Tabs.List")`; the backend renders it as
  `Tabs::ListComponent.new(...)` (was previously emitting invalid
  `Tabs.ListComponent.new`).
- **Spread props** — `JSXSpreadAttribute` lowers to `IR::SpreadAttribute`
  (replaces the broken `__spread__` placeholder). Component rest-binding
  (`function X({ a, ...rest })`) captured on `Component#rest_prop_name`.
- **`asChild` polymorphism** — `const Comp = cond ? Slot : "button"` plus
  `<Comp/>` synthesizes a Conditional with both branches expanded
  (Element for string-literal tags, ComponentInvocation for identifiers).
- **`cn()` / `clsx()` / `classnames()`** — recognized at lowering time;
  decomposed into IR::ClassList with literal segments, identifier
  interpolations, and conditional segments from object-literal arguments.
- **Inline styles** — `style={{ fontSize: 12 }}` lowers to IR::Style with
  kebab-case property names; identifier values become Interpolations.
- **Local JSX const inlining** — `const image = <Image .../>; <div>{image}</div>`
  inlines the JSX at the use site (also through ternary branches).
- **Local non-JSX `const` bindings** — preserved verbatim in a
  `<%# TODO: translate JS to Ruby %>` block at the top of the rendered
  template (not auto-translated; see policy note below).
- **React hooks detection** (`useState`, `useEffect`, `useRef`,
  `useContext`, `useMemo`, `useCallback`, `useReducer`,
  `useImperativeHandle`, `useLayoutEffect`, `useDebugValue`) — surfaced
  in their own TODO block pointing at the Hotwire/Stimulus alternative.
  Both `const [x, setX] = useState(...)` and bare `useEffect(...)`
  ExpressionStatements are captured.
- **Stimulus method extraction** — inline arrow event handlers
  (`onClick={() => …}`) and const-bound arrow handlers referenced from
  `onX={…}` lower to IR::StimulusBinding + IR::StimulusMethod. Backend
  emits a sibling `_controller.js` skeleton with the original JS body
  preserved as a comment.
- **Literal expression containers** — `{"foo"}`, `{42}` lower to plain
  text instead of `<%= "foo" %>`. `{true}` / `{null}` are dropped
  (matches React's runtime).
- **JSX comments** — `{/* foo */}` lowers to IR::Comment; renders as
  `<%# foo %>`.
- **JSX text whitespace normalization** — Babel's
  `cleanJSXElementLiteralChild` algorithm. Removes the indented blank
  lines that previously surrounded inline text.
- **Void element handling** — `<img />`, `<hr />`, `<br />`, `<input />`,
  etc. self-close; no spurious closing tag.
- **`key={…}` dropped** on both ComponentInvocation and Element (it's a
  React-only reconciliation hint, not a DOM attribute).
- **JSX member chains snake-cased** — `post.coverImage` → `@post.cover_image`
  (each chain segment, not just the root).
- **Template literals with member chains** — `` `/posts/${post.id}` `` →
  `"/posts/#{@post.id}"` (was previously flagged as TODO).
- **Unary expressions** — `!preview`, `-x`, `+x`, `!!flag` translate
  through to Ruby (`!@preview` etc.).
- **Lowering errors** carry line/column from the failing AST node.

### Added — backends

- **`Backend::ViewComponent`**:
  - **Sidecar layout** (default) per ViewComponent's `--sidecar`
    generator: `.rb` at the top level, `.html.erb` and any sibling
    Stimulus controller in a `<snake>_component/` subdirectory. Pass
    `layout: :flat` for the previous flat layout.
  - **Helper-call mapping** — `<Link>` → `link_to(...)`, `<Image>` →
    `image_tag(...)`. Override or extend via the `helpers:` kwarg;
    disable entirely with `helpers: false`.
  - **Element tag-builder mode** — switches to Rails' `tag.button(...)`
    builder when a SpreadAttribute is present on an HTML element
    (literal HTML stays for the no-spread case).
  - **Hyphenated kwargs** on ComponentInvocations emit as quoted-key
    hash entries (`"aria-label" => @x`) so they're valid Ruby.
  - **Initializer with `**rest`** when the source destructures a rest
    binding.
  - **Inlined attribute interpolation** — `href="/posts/<%= @slug %>"`
    instead of `href="<%= "/posts/#{@slug}" %>"` (template-literal
    inlining, previously only applied to className).
  - **Unresolved-identifier flagging** — interpolations whose translator
    result reports an unresolved name get a `<%# TODO: unresolved
    identifier "X" %>` marker.

- **`Backend::RailsView`** (new) — emits a single `<snake>.html.erb`
  with no Ruby class and no sidecar dir. Appropriate for pages tied to
  a route. Pass `--as=view` on the CLI or `backend: :rails_view` in the
  API. Stimulus controllers still emit alongside when applicable.

- **`Backend::RoutesScript`** (new) — turns IR::RouteTree into a
  reviewable Ruby script with `system "rails", "generate", "controller"`
  invocations and a suggested `config/routes.rb` block.

### Added — routes subcommand

- **`jsx_rosetta routes <input>`** parses `<Routes><Route>` JSX and
  emits the routes script. Member-expression element references
  (`<Layout.Home />`) flatten to the rightmost name. Recognized
  patterns: `path` is a string literal (`path="/x"` or `path={"/x"}`);
  `element` is a JSX element.
- **Resource consolidation** — `/xs` + `/xs/:id` pairs collapse into
  `resources :xs, only: %i[index show]` with a single
  `rails generate controller xs index show` call.
- **Catch-all routes** — `<Route path="*">` emits
  `match "*path", to: …, via: :all` (bare `*` is normalized to `*path`).
- **Reserved-name collision warning** — when a generated controller
  name matches a Rails reserved term, the script flags it.

### Added — IR types

`IR::SpreadAttribute`, `IR::ClassList`, `IR::ConditionalSegment`,
`IR::Style`, `IR::StyleDeclaration`, `IR::Comment`, `IR::LocalBinding`,
`IR::StimulusBinding`, `IR::StimulusMethod`, `IR::ReactHookCall`,
`IR::RouteTree`, `IR::RouteEntry`. `IR::Component` gains
`rest_prop_name`, `local_bindings`, `stimulus_methods`, and
`react_hooks` fields.

### Translation policy

- **Don't translate arbitrary JS to Ruby.** Bindings whose RHS isn't
  one of the narrowly-recognized shapes (literals, identifiers,
  member chains, simple template literals, `cn()`-style calls,
  inline-style object literals) get preserved verbatim in a TODO
  comment block. Speculative translation produced broken Ruby that
  looked plausible — worse than an obvious TODO.
- **Behavioral JS → Stimulus controllers.** Inline event-handler arrows
  extract to a generated `_controller.js` skeleton; `data-action`
  descriptors get auto-wired.
- **React hooks → Hotwire/Stimulus + server-side rendering.** Detected
  but not auto-translated; surfaced in a distinct TODO with
  alternatives noted.

### Verified end-to-end

- `vercel/next.js` `examples/blog-starter` — 15/16 components translate
  cleanly; the one failure (`theme-switcher.tsx`) uses
  `memo`+`useState`+`useEffect` and is structurally out of scope.
- A multi-route React Router app translates into a Rails 8.1 app with
  five routes (Home, PostsIndex, PostShow, About, NotFound)
  end-to-end. See `app/views/<controller>/<action>.html.erb` placement
  via `--as=view`.

## [0.1.0] - 2026-05-09

- Initial release. Phases 0–6: AST, IR, ViewComponent backend, slots,
  conditionals, events, loops, CLI.
