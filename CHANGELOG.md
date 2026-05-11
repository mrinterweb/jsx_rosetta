# Changelog

## [0.5.0] - 2026-05-11

Closes the four v0.5.0-candidate items from the v0.4.0 Phlex sample
review, plus the four larger features queued at the top of the
roadmap: Apollo + Next.js hook hint translation, class-component
support, AG-Grid column-descriptor module emission, and pretty-printing
for long object/array literals.

### Added — class-component support

- **`ClassDeclaration` → ViewComponent path.** Classes with a `render()`
  method now lower as components instead of getting flagged with the
  `:class_component` rejection. The `ExpressionTranslator` recognizes
  `this.props.X` and translates to `@x` (plus a snake_case member chain
  for `this.props.X.y.z`); `this.state.X` translates to `nil` since
  there's no Rails-side equivalent without a backing data source. Other
  class members (constructor, lifecycle hooks like
  `componentDidCatch`/`getDerivedStateFromError`, custom event handlers)
  get captured as LocalBinding-style TODO comments at the top of the
  view template so the reviewer sees the verbatim sources. Props are
  synthesized from direct `this.props.X` access AND from
  `const { X } = this.props` destructure patterns — the generated
  `initialize(...)` matches the original class's prop set.
  Stress-test impact: the 4 class-component residuals (ErrorBoundary
  and cousins) now translate cleanly.

### Added — AG-Grid column-descriptor module emission

- **Data-factory components.** `export const createColumns = (token,
  sortedInfo) => [{...}, {...}]` now lowers as an `IR::Component` with
  `mode: :data_factory`. Phlex emits a snake_case method that returns
  the translated array — `def create_columns(token: nil, sorted_info: nil)`
  — instead of `view_template`. JSX inside object properties extracts to
  private methods on the class via the existing IR::Lambda path
  (`render: method(:render_id_cell)`). ViewComponent backend emits a
  plain Ruby class with the method and a TODO note (the .erb pair is
  skipped — pure-data classes don't have a template). Multi-positional
  Identifier params are now also supported by `lower_params` — previously
  only single-arg React-style signatures lowered cleanly.

### Added — pretty-printing

- **Multi-line layout for long object/array literals.** When the single-
  line rendering of an `IR::ObjectLiteral` or `IR::ArrayLiteral` exceeds
  `LITERAL_INLINE_BUDGET` (80 chars), or contains a nested literal that
  itself wrapped, the layout switches to one entry per line indented
  two spaces past the parent line's indent. Closing bracket re-aligns
  to the parent indent. Short literals (typical Select options, small
  config objects) stay inline so non-AG-Grid output is unchanged. Helps
  readability of the column-descriptor output from the new
  data-factory path.

### Stress test outcome

- 929-file Phlex stress rerun: **895/929 clean translations**
  (up from 887/929 in v0.4.0 — 8 additional files now translate via
  the class-component and data-factory paths). **0/1240 emitted `.rb`
  files fail `ruby -c`** (unchanged; 16 more files emitted vs v0.4.0).
  221/929 files carry an Apollo TODO block (281 GraphQL operation
  names captured); 105/929 carry a Next.js navigation-hook block.
- 385 specs, all green; rubocop clean.

### Added — framework hook hints

- **Apollo data-fetching hooks recognized.** `useQuery`, `useLazyQuery`,
  `useMutation`, `useSubscription`, and `useApolloClient` are now
  detected at lowering time. Each call lands in `Component#react_hooks`
  tagged `library: :apollo`, with the GraphQL operation name extracted
  from a bare-Identifier first argument (`useQuery(GET_USERS_QUERY, …)`
  → `operation: "GET_USERS_QUERY"`). Both backends emit a dedicated
  Apollo TODO block above the template that points at the Rails analog
  (move the fetch to the controller; mutations become form POSTs or
  Turbo Stream responses). Operation names are echoed in the comment so
  the reviewer can match the call back to its GraphQL document.
  Destructured names (`{ data, loading, error }` from `useQuery`,
  `[mutate, { loading }]` from `useMutation`) are captured in
  `local_binding_names` so use sites translate to `nil` placeholders
  instead of raising NameError at render time.
- **Next.js navigation hooks recognized.** `useRouter`, `usePathname`,
  `useSearchParams`, `useParams`, `useSelectedLayoutSegment`, and
  `useSelectedLayoutSegments` get the same treatment — tagged
  `library: :next_js`, surfaced in a dedicated TODO block listing each
  hook's Rails equivalent (`useRouter` → `redirect_to`; `usePathname`
  → `request.path`; `useSearchParams` / `useParams` → `params`;
  `useSelectedLayoutSegment(s)` → pattern-match `request.path`).

The `ReactHookCall` IR type gains `library` and `operation` fields;
both backends group hooks by library and emit one TODO block per group.
React-only files keep the unchanged single-block output.

### Added

- **`BinaryExpression` and `LogicalExpression` translation.**
  `email.emailAttachments.length > 0` now translates to
  `@email.email_attachments.length > 0` instead of bailing to `if false`.
  Covers `===`/`!==`/`==`/`!=`/`<`/`>`/`<=`/`>=`/`&&`/`||`/`??`. JS-only
  operators map to their Ruby equivalents (`===` → `==`, `??` → `||`).
  Recursive splitting respects nested parens and string literals; outer
  parens are stripped so `(a > b) && c` parses cleanly.
- **Optional chaining (`?.`) → safe navigation (`&.`).** `user?.profile?.name`
  now emits `@user&.profile&.name` instead of leaving a Ruby SyntaxError
  in member-chain interpolations.
- **Nested render-function locals extracted to methods.**
  `const renderHeader = () => <h1/>; ... {renderHeader()}` previously
  dropped to `[untranslated: renderHeader()]`. New IR types `RenderMethod`
  and `LocalRenderCall` mean the arrow gets extracted to a private method
  on the Phlex class (`def render_header; h1 do; ...; end`) and the use
  site emits a direct call. Args translate through the same path as
  attribute interpolations. The ViewComponent backend emits a method
  skeleton with a TODO since ERB-method bodies don't translate cleanly
  to Ruby fragments.

### Fixed

- **`useCallback` / `useRef` / `useMemo` identifier bindings recognized.**
  `const handleChange = useCallback(...)` followed by
  `onChange={handleChange}` used to emit `on_change: handle_change`
  referencing a nonexistent method. The binding name is now captured in
  `Component#local_binding_names` so the translator emits `nil` at use
  sites, matching the destructure-pattern behavior added in v0.4.0.
- **Conditional guard on a known local no longer collapses to `if nil`.**
  `error && <X />` where `error` is destructured from a hook used to
  translate to `if nil` (the local-binding placeholder) — Ruby-valid but
  silently never-rendering. Both backends now treat a `"nil"` translation
  as untranslatable, falling through to the TODO-emission path so the
  reviewer sees what to fill in.

## [0.4.0] - 2026-05-11

Closes nine translation gaps identified during a sample review of 12
random Phlex outputs from the v0.3.0 stress run. Each gap was a silent
drop, a render-time NameError, or a semantic mistranslation — the
generated Ruby parsed but didn't behave like the source JSX.

### Added

- **Render-prop / function-as-children support.**
  `<Form.List>{(fields) => <p>{fields}</p>}</Form.List>` now lowers to a
  new `IR::RenderProp` and emits as a Ruby block on the parent `render`
  call: `render Form::List.new do |fields| ... end`. Both Phlex and
  ViewComponent backends emit the block; param names snake_case to match
  Ruby convention. Previously dropped as `plain "[untranslated: ...]"`.
- **Recursive object/array/lambda translation in attribute values.**
  New IR types `ObjectLiteral`, `ArrayLiteral`, and `Lambda` mean that
  `<Select options={[{ value: 10, label: "10 / page" }]} />` now emits
  `options: [{ value: 10, label: "10 / page" }]` (Ruby array of hashes)
  instead of `options: nil` with a TODO. Identifier keys snake_case
  (`dataLabel` → `data_label`); nested literals recurse. Function-valued
  properties — e.g. AG-Grid `render: (v) => <Tag>{v}</Tag>` — extract to
  private methods on the class (`def render_render(v); span do; ...; end`)
  and the property emits as `render: method(:render_render)` so the
  body has access to the Phlex tag.* helpers.
- **Module-level constants captured into `Component#module_bindings`.**
  `const FOO = 400; function X() { return <p>{FOO}</p>; }` no longer
  silently drops the FOO declaration — the backend emits a TODO comment
  block above the class with the original source so the reviewer either
  translates it to a Ruby constant or moves it to a Rails initializer.
- **Destructure-pattern names recognized by the translator.**
  `const [count, setCount] = useState(0); <p>{count}</p>` previously
  emitted a bare `plain count` that NameErrored at render time. The
  destructured names are now captured in `Component#local_binding_names`
  and the `ExpressionTranslator` emits a `nil` placeholder for them so
  the file at least loads. Covers `ArrayPattern`, `ObjectPattern`
  (including aliased properties, `AssignmentPattern` defaults, and
  `RestElement`), and hook-tuple destructures.
- **Member-expression destructure resolution.** `const { Content } = Layout`
  followed by `<Content/>` now resolves to `Layout::Content`, not a
  free-floating `ContentComponent`. Multiple destructured names from the
  same parent identifier all resolve correctly.

### Fixed

- **Component-prop callbacks no longer over-promote to Stimulus.**
  `<Select onChange={onChange} />` (PascalCase tag) previously emitted
  `data-action="change->foo#onChange"` — a Stimulus action descriptor
  that never fires because the receiving component is a Ruby class, not
  a DOM element. The lowering now checks `html_element?(tag)` before
  promoting `on*` attrs and treats component-prop callbacks as regular
  `IR::Attribute` kwargs. Stimulus promotion still applies to lowercase
  HTML tags as before. Closes a regression introduced by the v0.3.0
  prop-handler Stimulus promotion.
- **Spread-of-nil no longer raises at render time.** `<div {...maybeNil}>`
  used to emit `**@maybe_nil`, which raises when the prop is `nil`. Both
  Phlex and ViewComponent backends now wrap as `**(@maybe_nil || {})`.
  Cheap to emit unconditionally and idempotent.
- **Duplicate handler names are no longer silently renamed.** Two
  `onClick={handleReset}` handlers in one component previously produced
  `handleReset` / `handleReset2` with no marker. `StimulusMethod` now
  carries an `original_name` field, and the generated controller JS
  emits a `// NOTE: method renamed from "handleReset"` comment above the
  renamed method.
- **ReactNode-typed props get a `raw` hint comment.** When an
  interpolation translates to a bare `@ivar` reference (likely a prop),
  the Phlex backend emits a comment hint —
  `plain @extra # NOTE: use \`raw\` instead of \`plain\` if this is a
  ReactNode-typed prop`. `plain` HTML-escapes its argument, which is
  wrong for prebuilt-markup props but right for strings; we can't tell
  at translation time, so we default to safe (`plain`) and surface the
  choice.

### Investigation

- **Sibling named exports — not a gap.** Probed four shapes of
  `export default Foo; export function Loading() {}` against the gem;
  all four shapes correctly emit both `foo.rb` and `loading.rb`. Closed
  the suspected gap as a false positive from the random sample.

### Refactored

- `Lowering` class shrunk by ~150 lines (v0.3.0 prep, now shipping):
  pure-heuristic `ModuleShapeClassifier` lives in its own file; helper
  methods `AST::Node#child`, `#of_type?`, `Node.matches?` replaced ~25
  defensive `is_a?(AST::Node) && type ==` checks; class/style rendering
  in the ViewComponent backend deduplicated across HTML-vs-Ruby output
  formats; `tag_builder_data_action` replaced its "parse what I just
  emitted" heuristic with a structured `EventDescriptor` intermediate.

### Stress test outcome

- 929-file Phlex stress run on `reserv-web`: 887/929 clean translations
  (unchanged — rejection logic untouched), **0/1224 syntax failures**
  (down from 25 on v0.3.0). All emitted `.rb` files now pass `ruby -c`.
- Five residual bugs were caught during the v0.4.0 stress rerun and
  fixed inline:
  - Prop default expressions that translated to `nil # TODO: ...` inside
    `initialize(...)` swallowed the closing `)`. Prop defaults now route
    through the same recursive lowering as attribute values.
  - Multi-line JSX comments only prefixed the first line with `#`. Every
    line of a comment now gets a `#` prefix.
  - Template literals with inner `"` or `\\` characters could break the
    surrounding Ruby string. Literal segments now escape both.
  - `token.blue` (where `token` was a captured local binding) translated
    to `nil.blue` — `NoMethodError` at render time. Member-chain roots
    that resolve to a known-local binding now fall through to the
    snake_case bare reference with an unresolved marker rather than the
    `nil` placeholder.
  - `["a", "b"].map((x) => <li/>)` lost the array literal and emitted
    `[].each` because the translator can't parse `[...]`. The lowering
    now recognizes ArrayExpression iterables and routes them through
    the recursive ArrayLiteral path.

### Spec count

- Up to 343 examples (from 304), all green. `bundle exec rubocop` clean.

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
