# Roadmap

Forward-looking list of work items. Shipped releases are documented in
[CHANGELOG.md](CHANGELOG.md); the v0.1.0 design lives in [PLAN.md](PLAN.md).

Items are tagged by source so the lineage is traceable:
- **[review]** — surfaced by a subagent sample review of the Phlex
  stress run (highest signal — these are gaps seen in the wild).
- **[plan-oos]** — explicitly listed as out-of-scope in a prior release plan.
- **[stress]** — surfaced by the 929-file stress run rejection logs.

## Next up

v0.5.0 is shipping. Apollo + Next.js hook hint translation are done
(see the Done section). The next open larger features are class
components, AG-Grid module emission, and pretty-printing.

## v0.5+ — Larger features

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
- **v0.5.0** — Closed the four v0.5.0 candidate items from the
  v0.4.0 sample review **plus** the two larger features at the top
  of the v0.5+ list (Apollo + Next.js hook hint translation):
  - useCallback / useRef / useMemo identifier-bound hook results captured
    in `local_binding_names` so use sites emit `nil` instead of bare
    snake_case refs to nonexistent methods.
  - `BinaryExpression` / `LogicalExpression` translation in the
    `ExpressionTranslator` (incl. `===`/`!==`/`??` mapping).
  - Optional chaining (`?.`) → safe navigation (`&.`) in member chains.
  - Nested render-function locals (`const renderHeader = () => <div/>;
    ... {renderHeader()}`) extracted to private methods on the class.
  - `error && <X/>` guard on a known local no longer collapses to
    `if nil` — falls through to the TODO path.
  - Apollo hooks (`useQuery` / `useLazyQuery` / `useMutation` /
    `useSubscription` / `useApolloClient`) detected with the GraphQL
    operation name extracted from a bare-Identifier first argument;
    emitted as a dedicated TODO block pointing at the Rails controller
    fetch. Stress-test impact: 221/929 files now carry the Apollo block
    (281 operation names captured).
  - Next.js navigation hooks (`useRouter` / `usePathname` /
    `useSearchParams` / `useParams` / `useSelectedLayoutSegment(s)`)
    detected and surfaced in a dedicated TODO block listing each
    hook's Rails analog. Stress-test impact: 105/929 files now carry
    the Next.js block.
