# Changelog

## [Unreleased]

### Added

- **Phlex 2.x backend** — `--as=phlex` emits a single-file Phlex
  `view_template` Ruby class (no separate ERB sidecar). The JSX
  template lives as method calls inside `view_template`; attributes
  become snake_case kwargs (`h1(class: "foo", data_testid: @x)` —
  Phlex auto-hyphenates underscores in symbol keys at render time);
  control flow uses native Ruby (`if`, `.each`); children pass
  through `yield`. camelCase JSX attrs (`viewBox`, `preserveAspectRatio`)
  preserve verbatim so SVG works correctly. Three mutually exclusive
  naming strategies:
    * **default** — `class FlashyHeader < Phlex::HTML`, `flashy_header.rb`
    * **suffix** — `--phlex-suffix=Component` → `FlashyHeaderComponent`,
      `flashy_header_component.rb`. Defaults to `"Component"` if the
      flag is passed without a value.
    * **namespace** — `--phlex-namespace=Components` →
      `module Components; class FlashyHeader < Phlex::HTML`. Component
      cross-references inside the namespace stay bare (`render Card.new`)
      and resolve via Ruby's constant lookup.
  Stimulus handlers still emit a sibling `_controller.js` skeleton with
  the original JSX handler body preserved as a TODO comment.

### Refactored

- `Lowering` class shrunk by ~150 lines: pure-heuristic
  `ModuleShapeClassifier` lives in its own file; helper methods
  `AST::Node#child`, `#of_type?`, `Node.matches?` replaced ~25
  defensive `is_a?(AST::Node) && type ==` checks; class/style
  rendering in the ViewComponent backend deduplicated across
  HTML-vs-Ruby output formats; `tag_builder_data_action` replaced
  its "parse what I just emitted" heuristic with a structured
  `EventDescriptor` intermediate.

## [0.3.0] - 2026-05-10

Driven by a 929-file stress run against the entire `reserv-web` codebase
(`reserv-web/src/` + `reserv-web/pages/` + `packages/`). Baseline outcome
on v0.2.0: 838/929 (90.2%) clean exit, 91 hard failures across 5 distinct
error categories. This release ships fixes for all five plus a follow-up
that opens up lowercase JSX-returning helpers as components, lifting the
corpus to **887/929 (95.5%) clean exit**. The 42 remaining failures are
non-component modules (utility/hook libraries, AG-Grid column
descriptors, class-based ErrorBoundary components, side-effect
initializers); each now reports a classifier-tagged error that explains
*why* it didn't translate.

### Fixed

- **StringLiteral destructure keys no longer crash.**
  `function X({ "data-testid": dataTestId })` previously surfaced as a
  `bundler: failed to load command` after `Inflector.underscore(nil)` —
  the v0.2.0 ObjectPattern fix only handled `Identifier` keys. The
  lowering now reads `:value` from `StringLiteral` keys. Closes 11 files.
- **Hyphenated prop names emit valid Ruby.** `Inflector.underscore` now
  converts hyphens to underscores, so `data-testid` becomes `data_testid`
  in Ruby identifiers (kwarg, ivar). HTML attribute names continue to
  preserve hyphens — they're rendered from `Attribute.name` directly.

### Added — return-shape lowering

- **`return null;`, `return identifier;`, `return call();`** in return
  position. Previously each raised "unexpected JSX node in lowering: …"
  and crashed translation. The return-position dispatcher now accepts:
  - `NullLiteral` → empty `IR::Text` (renders nothing in ERB; valid as a
    Conditional alternate)
  - `Identifier` → `IR::Interpolation`, with inlining when the identifier
    is bound to a JSX local (`const card = <p/>; return card;`)
  - `CallExpression` → `IR::Interpolation` of the verbatim source
  Closes 20 files.
- **Trailing `switch` and `try` body shapes.** Component bodies whose
  only return path lives inside a trailing `switch (subject) { case A:
  return X; default: return Y; }` or `try { return X; } catch …` now
  lower cleanly. Switch fall-through groups (`case A: case B: return X;`)
  emit a single Conditional with an OR-joined test
  (`subject === A || subject === B`). Cases with multi-statement bodies
  (other than a single block-wrapped return) bail and the gem still
  raises "no return statement". Catch/finally handlers are dropped —
  they typically encode JS-only error semantics. Closes ~5 files.
- **Leading `if (X) return Y;` guards** wrap around any trailing return
  structure (return / if-chain / switch / try). Previously a guard
  before a trailing if-chain or switch was silently dropped (or caused
  the surrounding structure to bail).

### Added — what counts as a component

- **Lowercase-named JSX-returning helpers** (`textRender`,
  `booleanRender`, `cellFor`) now lower as components. The PascalCase
  rule was tightened to "PascalCase OR (lowercase + body returns JSX,
  excluding `use*` hook names)." A pre-lowering AST scan walks the
  function body's return paths (recursing into BlockStatement,
  IfStatement, SwitchStatement, TryStatement, ConditionalExpression,
  LogicalExpression) to detect any reachable JSX value. Closes ~10
  utility-renderer files.
- **Permissive return-position dispatcher.** Function bodies that
  return arbitrary non-JSX expressions (`return money.formattedValue;`,
  `return computeValue();`, `` return `${name}` ``) now lower cleanly.
  Member access, template literals, binary expressions, and other
  bare-expression returns become `IR::Interpolation`; string and
  numeric literals become `IR::Text`. This is what makes lowercase
  JSX-helpers tractable — their guard returns are usually non-JSX.
- **Implicit-return arrow bodies of any shape.** Previously
  `const X = () => <div/>` worked but `const X = () => cond ? <a/> : <b/>`
  raised "unsupported component body". The body dispatcher now routes
  any non-block body through the return-position dispatcher.

### Improved

- **Module-shape classifier with eight labels and per-shape messages.**
  Every `no component function found in module` error now appends a
  specific label and a concrete suggestion: `:hoc_wrapped` (peel
  `React.memo` / `forwardRef` / `lazy` / `observer`), `:class_component`
  (rewrite as a function), `:hooks_only` (move behavior to Stimulus,
  state to ivars), `:columns_data` (data lives in models or presenters),
  `:types_only` (TypeScript types erase), `:utils_only` (only
  JSX-returning helpers translate), `:mixed_exports` (split the file),
  `:side_effects_only` (use a Rails initializer). Stress-test
  validation: 42 remaining failures, 0 unlabeled.

## [0.2.0] - 2026-05-10

Driven by an empirical probe of v0.1.0 against a 39-file Next.js production
slice (`reserv-web/src/components/rolloverbook`). The slice exposed three
return-shape gaps and a crash on nested destructure; this release fixes all
four. Probe outcome: 33/39 → **39/39 emit**.

### Fixed

- **Nested-destructured props no longer crash the lowering.**
  `function X({ outer: { inner } })` previously surfaced as
  `Inflector.underscore(nil)` in the backend. The lowering now uses the
  outer key as the prop name. Renamed destructures (`{ outer: inner }`)
  similarly use the source-side key (the prop name the parent passes),
  not the renamed local.

### Added — return-shape lowering

- **Top-level conditional / short-circuit returns** —
  `return cond ? <A/> : <B/>` and `return cond && <A/>` now lower to
  IR::Conditional via a new return-position dispatcher. Previously raised
  "unexpected JSX node in lowering: ConditionalExpression".
- **Multi-branch `if/else if/else` all-return bodies** — components
  whose every return path lives inside an if-chain (no top-level
  unconditional return) lower to a chained IR::Conditional. Branches
  may be braced single-statement blocks (`if (x) { return <A/>; }`) or
  bare returns (`if (x) return <A/>;`). Branches with side-effect
  statements before the return still raise — those imply behavior we
  can't preserve.

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
