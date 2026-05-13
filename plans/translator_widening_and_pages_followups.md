# jsx_rosetta — translator widening + pages-router follow-ups

Umbrella plan for ten follow-up items surfaced by the post-merge stress assessment (covers items #2, #3, #4, #5, #6, #7, #8, #9, #11, #12 from the readiness review). Organized into three slices, ordered by independence and impact-per-LOC.

Parent plans this builds on: `plans/nextjs_pages_to_rails.md` and its slice 2 / slice 3 spinoffs.

Each slice below will get its own implementation plan file when it starts, matching the slice-1/2/3 cadence. This document is the umbrella that organizes the work and locks in the sequencing.

## Inventory

The ten items, grouped by where the work lands. The cross-references like "(former #2)" map back to the original list in the readiness assessment.

### Group A — ExpressionTranslator widening (Slice A)

Reduces TODO surface across **every** generated file. Self-contained; no Next.js-specific surface area.

- **A1. Simple-condition translator widening** (former #2). Conditional-render guards like `{loading && <X/>}` should emit `if @loading`, not `# TODO: translate condition: loading`. The translator already handles bare identifiers, member chains, and unary `!` in attribute-value context — the conditional-rendering path bails on the same shapes for reasons that need diagnosing. **Stress corpus impact**: ~123 TODOs (61 "render guard couldn't translate" + 41 + 21 simple-condition TODOs).

- **A2. Trivial top-level const → Ruby constant** (former #3). Every module-level `const` lands in a TODO block today. Many are `const FOO = "literal"` / `const COLUMNS = [...]` / `const TAGS = {...}` — literal-shaped values that translate cleanly using the same machinery as the merge's cva path. **Stress corpus impact**: ~402 TODO blocks affected.

- **A3. `router.push("/path")` hint outside event-handler bodies** (former #6). When the call appears in a synchronous body (not an event handler), emit `# TODO: redirect_to <helper>` referencing the matched URL helper. Handler bodies stay verbatim per the project rule against speculative JS-to-Ruby translation. Smaller surface (<50 occurrences in this corpus) but a high-signal hint when it fires.

### Group B — Next.js page-router extensions (Slice 4 of the parent series)

Builds on slice 1's `pages-routes` and slice 2's `--rails-routes` view placement. Shipping them together keeps the routes.rb, the view tree, and the controller stubs in sync.

- **B1. `getServerSideProps` / `getStaticProps` detection** (former #4). Capture the body at lowering time into a new field on `IR::Component`; emit a TODO comment block at the top of the rails-view file (and a matching one in the controller action stub) with the body verbatim. The only place in slice 4 where AST/IR meaningfully helps.

- **B2. `_app.tsx` / `_document.tsx` → application-layout class** (former #5). Stop skipping at the `pages-routes` layer. Translate to `app/views/layouts/application.rb` with class `Views::Layouts::Application < Views::Base`. The merge's auto-yield mechanism is exactly the body shape this needs.

- **B3. Namespace nesting for nested dirs** (former #7). `pages/admin/users/[id].tsx` should produce `Admin::UsersController#show` at `/admin/users/:id` (not the current `admin#users_show`). Trigger: more than one non-bracket directory segment before the leaf.

- **B4. Error-page support** (former #8). `_error.tsx` / `404.tsx` / `500.tsx` → `Views::Errors::<Status> < Views::Base` at `app/views/errors/<status>.rb`, plus a comment block at the top of routes.rb explaining `config.exceptions_app` wiring.

- **B5. Route groups `(group)/`** (former #11). Next.js 13+ pattern where paren-wrapped directories are invisible to the URL but group files semantically. Rule: skip the segment from URL building; carry it through as a controller namespace hint.

### Group C — Slice-3 backend expansion (Slice C)

Extends slice 3's link-tag reach and the slice-2/3 `--rails-routes` plumbing to the other backends.

- **C1. `<form action="...">` rewrite** (former #9). Extend slice 3's link-tag set: `form` joins `a` / `Link` / `NavLink` / `RouterLink`, with `action` instead of `href`. Only rewrite when `method` is GET or absent (HTML default). Slice 1 emits GET routes only, so non-GET forms stay verbatim until the route table grows.

- **C2. `--rails-routes` for ViewComponent + RailsView backends** (former #12). The Phlex backend has full slice-2/3 support today; the other two don't. Add equivalent view placement (and href rewriting where it makes sense) to `Backend::ViewComponent` and `Backend::RailsView`.

## Slice plans

### Slice A — translator widening

**Why first**: highest TODO-reduction-per-LOC. Self-contained, no Next.js surface. Lowers visible TODO count on every translation; would lift the stress corpus from ~3.9 TODOs/file mean toward ~2.5.

**Likely files**:

| Path | Status | Scope |
|---|---|---|
| `lib/jsx_rosetta/backend/view_component/expression_translator.rb` | modify | Accept conditional-render context; return `@ivar` for simple bucket-4 hits with unary `!` prefix preserved. Investigate why the conditional path bails on shapes the attribute-value path accepts — likely a stricter entry point. |
| `lib/jsx_rosetta/ir/lowering.rb` | modify | New detector for literal-shaped module-level `const` declarations (string, number, boolean, array of literals, object of literals). Mirror the `try_lower_cva_call_site` pattern. |
| `lib/jsx_rosetta/ir/types.rb` | modify | New `IR::ModuleConstant` value type (parallel to `IR::CvaBinding`). |
| `lib/jsx_rosetta/backend/phlex.rb` | modify | Emit `IR::ModuleConstant` as a real Ruby constant above the class — reuses the section/ordering of `render_cva_constants`. Also: `router.push("/...")` hit detection in synchronous bodies, emit comment hint using the `@href_rewriter` when present. |

**Verification**: stress-corpus re-run with before/after TODO counts; new specs for the three behaviors.

### Slice 4 — Next.js page-router extensions

**Why second**: every item depends on slice 1 / slice 2 plumbing that already landed. All five items touch `pages-routes` and `translate --rails-routes` together — shipping them as one slice avoids partial-state where the routes.rb expects namespaces but the view tree doesn't (or vice versa).

**Behavior change to flag in the slice-4 plan**: namespace nesting changes the route table for any pages tree with multi-segment dirs. Parallel to slice 3's `as:` addition — intentional and documented.

**Likely files**:

| Path | Status | Scope |
|---|---|---|
| `lib/jsx_rosetta/pages_routing.rb` | modify | (a) Route groups: `Scanner` ignores `(group)` dirs for URL building but stores them in a new `namespace` array on `Route`. (b) Namespace nesting: when more than one non-bracket segment precedes the leaf, treat all but the last as namespaces. `Naming.route_name` and `Emitter.route_line` follow. (c) Stop skipping `_error.tsx` / `404.tsx` / `500.tsx`; emit them as `Route(controller: "errors", action: "<status>", ...)` plus a `config.exceptions_app` comment block at the top of routes.rb. (d) Stop skipping `_app.tsx` / `_document.tsx`; slice 2's view-placement gets a `layout: true` variant. |
| `lib/jsx_rosetta/backend/phlex.rb` | modify | Accept `layout: true` on the `rails_view:` option (or split into a new `rails_layout:` option — pick at slice-4 plan time). Layout emission uses `Views::Layouts::Application < Views::Base` with the `yield if block_given?` body. |
| `lib/jsx_rosetta/ir/lowering.rb` + `types.rb` | modify | Capture `export async function getServerSideProps(...)` / `export const getServerSideProps = ...` source verbatim into a new `IR::Component#server_data_source` field. Phlex backend emits as a TODO comment block at the top of the view, pointed at the controller action. |

**Verification**: synthetic pages tree exercising each shape (route group, namespace, error page, `_app`, getServerSideProps); stress-corpus pages re-run to confirm the 82 pages still produce valid routes.

### Slice C — slice-3 backend expansion

**Why third (or interchangeable with slice 4)**: smallest scope. Independent of slice 4 — could ship before, after, or in parallel without conflict.

**Likely files**:

| Path | Status | Scope |
|---|---|---|
| `lib/jsx_rosetta/backend/phlex.rb` | modify | Extend `LINK_TAGS` with `form`; restructure `HREF_ATTR_NAMES` so `form` matches `action` rather than `href`. Detect the form's `method` attribute (default GET) and only rewrite when GET. |
| `lib/jsx_rosetta/backend/view_component.rb` | modify | Accept `rails_view:` + `route_table:` Phlex-style. Output paths follow `app/views/<controller>/<action>.html.erb` (template) + `<action>_component.rb` (class). |
| `lib/jsx_rosetta/backend/rails_view.rb` | modify | Accept `rails_view:` + `route_table:` Phlex-style. Single-file layout, path becomes `app/views/<controller>/<action>.html.erb`. |
| `lib/jsx_rosetta.rb` | modify | Allowlist `:rails_view, :route_table` for the ViewComponent and RailsView backends (already there for Phlex). |
| `lib/jsx_rosetta/cli.rb` | modify | Lift the `--rails-routes requires --as=phlex` guard. |

**Verification**: synthetic TSX with `<form action="/x" method="get">`; CLI tests for `translate --as=view --rails-routes <dir>` and `translate --as=view_component --rails-routes <dir>`.

## Sequencing

```
slice A ──┐
          ├─→ (independent) ─→ slice 4
slice C ──┘                    (only depends on slices 1-3, already landed)
```

**Recommended order**: A first (highest TODO-reduction-per-LOC and broadest reach), then 4 (Next.js-specific value, ships the page-router story end-to-end), then C (smallest scope, additive). Reorder freely if the user prefers — none of the three blocks any other.

## Out of scope for this umbrella

- **HOC unwrapping** (former #1, deliberately omitted from this plan per user direction). Belongs in its own plan when we're ready to decide on the unwrap rules across `React.memo` / `forwardRef` / `lazy` / `observer` / Redux `connect`.
- **Anchor / query-string preservation** (former #10, deliberately omitted). Defer until a corpus hits it materially.
- **User-side gaps** from the readiness assessment — React/Apollo hooks, theme tokens, custom-hooks modules. The gem deliberately doesn't translate these.

## Risks

- **Slice A condition widening false positives.** If the translator accepts a shape it shouldn't, the conditional renders against an `@ivar` that doesn't exist → render-time NameError. Mitigation: only widen to identifiers and member expressions whose root is in `prop_names` / `local_binding_names`; everything else continues to bail with a TODO. Same five-bucket discipline as the existing translator.

- **Slice A const detection over-reaches.** A module-level `const FOO = useSomething()` would emit a Ruby constant referencing a JS expression. Mitigation: only lower constants whose initializer is a *literal* (string / number / boolean / null / array of literals / object of literals). Call expressions, member access, identifiers — all bail to the existing TODO block.

- **Slice 4 routes.rb is a breaking change.** Namespace nesting renames route helpers for any pages tree with multi-segment dirs (`/admin/users` → `admin_users_path` rather than `admin_users_show_path`). Document it in the slice-4 plan as a behavior change, parallel to slice 3's `as:` addition. Users with custom `as:` overrides should regenerate.

- **Slice C ViewComponent surface is bigger than Phlex's.** ViewComponent's sidecar layout (class + ERB template) means two emission paths instead of one. The slice-2 helpers may need extracting to a shared module before they apply cleanly.

- **B1 `getServerSideProps` capture is verbatim, not translated.** Risk: users expect it to "just work" once captured. Mitigation: emit the body explicitly as `# TODO: port this to <controller>#<action>` with a clear header so the expectation is set at the comment level.
