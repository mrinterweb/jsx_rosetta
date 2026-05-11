# Roadmap

Forward-looking list of work items. Shipped releases are documented in
[CHANGELOG.md](CHANGELOG.md); the v0.1.0 design lives in [PLAN.md](PLAN.md).

Items are tagged by source so the lineage is traceable:
- **[review]** — surfaced by a subagent sample review of the Phlex
  stress run (highest signal — these are gaps seen in the wild).
- **[plan-oos]** — explicitly listed as out-of-scope in a prior release plan.
- **[stress]** — surfaced by the 929-file stress run rejection logs.

## Next up — v0.5.0 candidates

The four items below are the highest-leverage residuals from the
v0.4.0 sample review. Each one was observed multiple times across
random samples and is a real render-time bug, not a cosmetic issue.

- [ ] **Locally-declared `useCallback` / function names leak as bare refs.**
  `const handleChange = useCallback(...)` followed by
  `onChange={handleChange}` emits `on_change: handle_change` referencing
  a method that doesn't exist on the class. The hook source is
  preserved in the TODO block but the use site has no marker.
  *Fix sketch:* extend `Component#local_binding_names` capture in
  `Lowering#collect_local_bindings` to include `const X = useCallback(...)`
  bindings; translator already handles the rest. [review]
- [ ] **Nested render-function locals drop to `[untranslated: ...]`.**
  `const renderHeader = () => <div/>; ... {renderHeader()}` — the call
  expression is opaque to `lower_call_expression`.
  *Fix sketch:* recognize `CallExpression` whose callee resolves to a
  local arrow returning JSX; extract to a private method on the class
  (like Gap H's lambda extraction) and reference via `render_header`. [review]
- [ ] **Trivially-translatable `BinaryExpression` conditions emit `if false`.**
  `email.emailAttachments.length > 0` could translate to
  `@email.email_attachments.length > 0` but `ExpressionTranslator`
  doesn't handle `BinaryExpression` (or `LogicalExpression` at the
  expression level). Lots of guards bail to the safe `# TODO` + `if false`
  placeholder for no good reason.
  *Fix sketch:* add `BinaryExpression` and `LogicalExpression` branches
  to `translate_ruby` in `expression_translator.rb`. Map JS operators to
  Ruby: `===` → `==`, `!==` → `!=`, `??` → `||`. Optional chaining
  (`?.`) needs `&.`. [review]
- [ ] **`error && <X />` guard collapses to `if nil` for destructured locals.**
  When the test resolves to a known local binding, `Gap C`'s
  `safe_test_expression` returns `nil` (the Gap A placeholder) instead
  of bailing to the `# TODO` path. The `if nil` is Ruby-valid but the
  whole branch silently never renders.
  *Fix sketch:* detect when the translated expression is just `nil` and
  treat it as untranslatable (fall through to the TODO emission). [review]

## v0.5+ — Larger features

- [ ] **Apollo `useQuery` / `useMutation` hint translation.** These hooks
  encode data fetching; map to a TODO that points at the Rails
  controller / model fetch they should become, with the GraphQL
  operation name preserved. [plan-oos]
- [ ] **Next.js navigation hooks hint pass** — `useRouter`,
  `usePathname`, `useSearchParams`. Surface a per-hook TODO pointing at
  the Rails analog (`request.path`, `params`, `redirect_to`). [plan-oos]
- [ ] **`ClassDeclaration` → ViewComponent path.** The 4 class-based
  components currently rejected at lowering (`ErrorBoundary` and
  cousins) could lower if we handle `render() {}` method extraction. [plan-oos]
- [ ] **AG-Grid column-descriptor module emission.** Files that are
  entirely `export const columns = [...]` get rejected as
  `columns_data`. Could emit a Ruby presenter / module with the
  column descriptors translated via Gap H's recursive lowering. [plan-oos]
- [ ] **Pretty-printing long object/array literals.** Gap H emits
  single-line output; long AG-Grid columns become unreadable. Add
  multi-line formatting with deterministic indentation. [plan-oos]

## Stress-test residuals (42/929 rejected)

The non-component-shape rejections each have a classifier-tagged error
message; most are intentional drops. Worth revisiting if a specific
shape becomes high-value:

- [ ] Custom-hooks modules (`useFoo.ts` returning behavior) —
  classifier says "translate behavior to Stimulus." [stress]
- [ ] Side-effect-only modules — classifier says "register in a Rails
  initializer." [stress]
- [ ] Types-only / constants-only modules — currently dropped; could
  emit Ruby constants for the constants subset. [stress]
- [ ] Mixed-export modules — classifier asks the human to split the
  file. No automated fix planned. [stress]

## Polish / quality

- [ ] **Spec coverage gap.** Some v0.4.0 fixes (template-literal
  escaping, multi-line comment prefixing) have one spec each; consider
  fuzzing across a broader corpus.
- [ ] **README update.** v0.3.0 added the Phlex backend, v0.4.0 closed
  many gaps — README still describes the v0.2.0 ViewComponent-only
  surface. Add a Phlex section and an example of the recursive
  object-literal translation.
- [ ] **CHANGELOG TLDR.** The v0.4.0 entry is dense; a one-paragraph
  "what this means for users" intro would help.

## Done — historical reference

See [CHANGELOG.md](CHANGELOG.md). Major arcs to date:
- **v0.1.0** — ViewComponent backend, three-stage pipeline.
- **v0.2.0** — Stimulus extraction, sidecar layout, helpers, RailsView,
  routes, compound components, asChild polymorphism, React hooks.
- **v0.3.0** — Phlex 2.x backend (three naming strategies), 887/929
  clean translations.
- **v0.4.0** — Closed nine gaps surfaced by a sample review of v0.3.0
  Phlex output (A, B, D, E, F, G, H, J, K); 0/1224 syntax failures
  (down from 25); 343 specs.
