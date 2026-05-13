# Slice 4 — Next.js page-router extensions (umbrella: `translator_widening_and_pages_followups.md`)

Five extensions to the page-router story shipped in slices 1–3. Each item touches either `pages_routing.rb` (route classification) or the Phlex backend's `--rails-routes` plumbing (view placement), and several touch both. Land as one slice so the routes.rb, the view tree, and any controller stubs stay in sync.

Items from the umbrella plan, in landing order:

- **B5** — Route groups `(group)/`. Next.js 13+ convention where paren-wrapped dir segments are invisible to the URL but group files semantically. Skip the segment from URL building; carry through as namespace hint. *Lands first — pure Scanner change, no IR / backend coupling.*
- **B3** — Namespace nesting for multi-segment dir trees. `pages/admin/users/[id].tsx` → `Admin::UsersController#show` at `/admin/users/:id` (today: `admin#users_show`). **Documented breaking change.**
- **B4** — Error pages (`_error.tsx` / `404.tsx` / `500.tsx`) → `Views::Errors::<Status>` at `app/views/errors/<status>.rb`. Adds a `config.exceptions_app` comment block at the top of routes.rb.
- **B2** — `_app.tsx` → `app/views/layouts/application.rb` with class `Views::Layouts::Application < Views::Base`. `_document.tsx` remains skipped (HTML scaffolding is Rails's job).
- **B1** — `getServerSideProps` / `getStaticProps` capture into new `IR::Component#server_data_source` field. Phlex backend emits the body as a TODO comment block at the top of the rails-view file. The one item in slice 4 where AST/IR meaningfully helps.

## Dependencies

```
B5 ──┐
     ├─→ B3 ─→ B4 ─→ B2 ─→ B1
B3 ──┘
```

B5 and B3 both reshape `controller_for` / `route_name` in `PagesRouting::Naming`; landing B5 first means B3 doesn't have to re-handle paren-wrapped segments. B4 / B2 / B1 are independent and could ship in any order — sequencing them last keeps the routes.rb regression in one place.

## B5 — Route groups `(group)/`

### Detection

`Scanner.segment_to_path_part` already classifies bracketed segments. Add a `(group)` form: `\A\(([^)]+)\)\z` → `[:route_group, name]`. Two rules follow:

1. `rails_path_for` skips `:route_group` entries entirely (no URL segment).
2. `controller_for` treats `(group)` dirs as transparent — picks the first *non-group, non-bracket* segment. The group name is collected separately into a new `namespace` array on `Route`.

### Route shape

```ruby
Route = Data.define(:rails_path, :controller, :action, :source_path, :namespace)
```

`namespace` is `[]` for everything not under a group. Under `pages/(marketing)/about.tsx` it's `["marketing"]`. Under `pages/(marketing)/(public)/about.tsx` it's `["marketing", "public"]` (rare but valid).

### Naming

`Naming.route_name` prefixes the namespace: `["marketing"] + about` → `marketing_about_path`. URL still `/about`.

### Emitter

routes.rb wraps grouped routes in `namespace :marketing, module: "marketing", path: ""` blocks so Rails picks up the controller path (`Marketing::AboutController`) without affecting the URL. Comment above the block names the source group.

### Files

| Path | Status | Scope |
|---|---|---|
| `lib/jsx_rosetta/pages_routing.rb` | modify | `Route` gets `namespace:`. Scanner's `segment_to_path_part` + `controller_for` + `rails_path_for` handle the new form. Emitter renders nested `namespace … path: ""` blocks for grouped routes. Naming prefixes route-name helper. |

### Specs

- `pages/(marketing)/about.tsx` → `get "/about"` with `as: :marketing_about` inside `namespace :marketing, path: ""`.
- `pages/(marketing)/index.tsx` → `get "/"` with `as: :marketing_index`.
- `pages/(marketing)/(public)/about.tsx` → nested namespaces.
- `pages/(group)/users/[id].tsx` → group + bracket dir → `Group::UsersController#show` at `/users/:id`.

## B3 — Namespace nesting for nested dirs

### Trigger

In `controller_for(dir_segments)`, current behavior: first non-bracket segment wins. New rule: when **more than one** non-bracket segment precedes the leaf, treat all but the last as namespaces and the last as the controller.

Examples:

| Source path | Before | After |
|---|---|---|
| `users/[id].tsx` | controller=`users`, action=`show` | unchanged |
| `admin/users/[id].tsx` | controller=`admin`, action=`users_show` | namespace=`["admin"]`, controller=`users`, action=`show` |
| `admin/users/[id]/edit.tsx` | controller=`admin`, action=`users_edit` | namespace=`["admin"]`, controller=`users`, action=`edit` |
| `admin/billing/invoices/index.tsx` | controller=`admin`, action=`billing_invoices_index` | namespace=`["admin", "billing"]`, controller=`invoices`, action=`index` |

Bracket dirs *between* the controller and the leaf still flow into the URL as params; they don't break namespacing. `policies/[providerSlug]/[policyId]/edit.tsx` stays controller=`policies` because there's only one non-bracket dir.

### Naming & emission

`Naming.route_name` prepends namespace segments to the existing rule. `Admin::UsersController#show` → `as: :admin_user`. Emitter wraps the controller's route block in `namespace :admin do ... end`.

### Behavioral interaction with B5

B5's namespace (from `(group)`) and B3's namespace (from nested dirs) collapse into the same `namespace` array on Route, in source order. A grouped *and* nested path like `pages/(marketing)/admin/users/index.tsx` produces `namespace = ["marketing", "admin"]`, controller=`users`. Rendered as two nested `namespace` blocks in routes.rb.

### Breaking-change notice

Existing route-name helpers change for any pages tree with multi-segment dirs:

- `admin_users_index_path` → `admin_users_path`
- `admin_users_show_path` → `admin_user_path(id)`
- `admin_billing_invoices_index_path` → `admin_billing_invoices_path`

Document in the slice-4 plan and in the CHANGELOG when shipped. Parallel to slice 3's `as:` addition: intentional rename, surfaced clearly.

### Files

| Path | Status | Scope |
|---|---|---|
| `lib/jsx_rosetta/pages_routing.rb` | modify | `controller_for` returns `[controller, namespace_array]`. `Naming.route_name` & `url_helper_name` accept namespace. `Emitter.grouped_body` wraps in nested `namespace :foo do` blocks. `HrefRewriter` ignores namespace for path-matching — the rails_path string already contains everything URL-relevant. |
| `lib/jsx_rosetta/backend/phlex.rb` | modify | `rails_view_class_name` prepends namespace: `Views::Admin::Users::Show`. `ruby_path` prepends: `admin/users/show.rb`. |
| `lib/jsx_rosetta/cli.rb` | unchanged | The `--rails-routes` flow already plumbs the Route through; the namespace travels along for free. |

### Specs

- Two-segment nesting (`admin/users/[id].tsx`) → emits `namespace :admin do; resources :users, only: [:show]; end`-equivalent flat block.
- Three-segment nesting → two nested namespace blocks.
- Bracket dir between named segments doesn't break detection.
- HrefRewriter: literal `"/admin/users/123"` matches namespaced route, returns `admin_user_path(123)`.

## B4 — Error pages

Stop skipping `_error.tsx` / `404.tsx` / `500.tsx`. Emit as:

```ruby
Route(
  rails_path: "/404",  # informational; not actually used as a Rails route
  controller: "errors",
  action: "not_found",  # or "internal_server_error" / "fallback"
  source_path: "404.tsx",
  namespace: [],
  kind: :error_page
)
```

Add a `:kind` field on `Route` (default `:standard`). Routes with `kind: :error_page` are NOT emitted as `get` lines in routes.rb — instead they get a comment block at the top explaining `config.exceptions_app = routes` wiring:

```ruby
# Error pages — wire in config/application.rb:
#   config.exceptions_app = self.routes
# Then declare these as ordinary routes that resolve to ErrorsController:
#   match "/404", to: "errors#not_found", via: :all
#   match "/500", to: "errors#internal_server_error", via: :all
```

View placement still applies — `_rails_view_route` for an error page points at `app/views/errors/<action>.rb` with class `Views::Errors::<Action>`.

Action name mapping:

| Source | Action |
|---|---|
| `404.tsx` | `not_found` |
| `500.tsx` | `internal_server_error` |
| `_error.tsx` | `fallback` |

### Files

| Path | Status | Scope |
|---|---|---|
| `lib/jsx_rosetta/pages_routing.rb` | modify | `Route` gets `kind:`. `Scanner.build_route` recognizes error leaves; `SKIPPED_LEAVES` loses the error entries. `Emitter` emits the wiring comment block at the top of routes.rb when any error-page route is present; skips them from the `get` list. |
| `lib/jsx_rosetta/backend/phlex.rb` | unchanged | `rails_view_class_name` already does `Views::<Controller>::<Action>` — `errors/not_found.rb` falls out naturally. |

### Specs

- `404.tsx` → Route(`controller: "errors"`, `action: "not_found"`, `kind: :error_page`).
- Emitter inserts the wiring comment block when error pages are present.
- View placement: translating `404.tsx` with `--rails-routes` lands at `errors/not_found.rb` with class `Views::Errors::NotFound < Views::Base`.

## B2 — `_app.tsx` → application layout

Stop skipping `_app.tsx`. Emit as:

```ruby
Route(
  rails_path: nil,
  controller: "layouts",
  action: "application",
  source_path: "_app.tsx",
  namespace: [],
  kind: :layout
)
```

`_document.tsx` stays in `SKIPPED_LEAVES` — Next.js's `_document` exists to override the HTML scaffolding (lang attribute, custom head/body wrappers), and Rails owns that via `app/views/layouts/application.html.erb`. We don't try to translate.

### View placement

The Phlex backend translates layouts to `app/views/layouts/application.rb` with class `Views::Layouts::Application < Views::Base`. Body is the body of the `_app.tsx` component — Next.js's `_app` typically returns `<Component {...pageProps} />` wrapped in providers, so the translation lands as:

```ruby
# Views::Layouts::Application — generated by jsx_rosetta from _app.tsx
class Views::Layouts::Application < Views::Base
  def view_template
    # TODO: Next.js providers detected — port to Rails initializers / Stimulus:
    #   <ThemeProvider> ... <Component {...pageProps} /> ... </ThemeProvider>
    yield if block_given?
  end
end
```

The `<Component {...pageProps} />` invocation in the source lowers to a special marker that the backend emits as `yield if block_given?`. Provider wrappers around it stay as TODO comments — wrapping behavior usually doesn't translate verbatim to Rails.

Detection rule: in lowering, when `mode == :layout` (a new mode), the lowering pass recognizes `<Component {...pageProps} />` (camelCase `Component` referencing the page-props param) and replaces it with an `IR::LayoutYield` node. The backend emits `yield if block_given?`.

### Files

| Path | Status | Scope |
|---|---|---|
| `lib/jsx_rosetta/pages_routing.rb` | modify | `Scanner` recognizes `_app` as a layout route, not skipped. `Emitter` lists it in the skipped-block-style comment header but doesn't emit it as a `get` line. |
| `lib/jsx_rosetta/ir/types.rb` | modify | New `IR::LayoutYield` node (no fields). New `mode: :layout` value on Component. |
| `lib/jsx_rosetta/ir/lowering.rb` | modify | When the function's body is a JSX element wrapping `<Component {...pageProps} />`, lower the inner `<Component ...>` as `LayoutYield`. The wrapping providers stay as ComponentInvocation TODOs (their children include the LayoutYield). |
| `lib/jsx_rosetta/backend/phlex.rb` | modify | New rendering branch for `IR::LayoutYield` → `yield if block_given?`. When `@rails_view.kind == :layout`, `rails_view_class_name` → `Views::Layouts::Application`. `ruby_path` → `layouts/application.rb`. |

### Specs

- `_app.tsx` returning bare `<Component {...pageProps} />` → emits `yield if block_given?` body.
- `_app.tsx` wrapping in providers → providers become ComponentInvocation TODOs, the inner `<Component …>` becomes a yield.
- Class name and path for layouts.

## B1 — `getServerSideProps` / `getStaticProps` capture

### Detection

After parsing, scan the top-level AST `body` for one of:

- `ExportNamedDeclaration` whose `declaration.type` is `FunctionDeclaration` with `id.name` in `{"getServerSideProps", "getStaticProps"}` (sync or async).
- `ExportNamedDeclaration` whose `declaration.type` is `VariableDeclaration` and the first declarator's `id.name` is in the same set, with `init` an `ArrowFunctionExpression` or `FunctionExpression`.

Capture the full source range of the export statement verbatim. Attach to the component via a new `server_data_source:` field on `IR::Component`. When multiple sibling components share the same module (rare for pages but possible), the field attaches only to the default-export component.

### Field

```ruby
# server_data_source : ServerDataSource | nil — capture of an exported
#                      getServerSideProps / getStaticProps function. Body is
#                      preserved verbatim so the human reviewer can port it
#                      to the matching Rails controller action. nil for
#                      non-page components.
ServerDataSource = Data.define(:hook_name, :source) do
  include Node
end
```

### Phlex emission

When `@rails_view` is set and `component.server_data_source` is non-nil, prepend a TODO comment block above the class:

```ruby
# TODO: port this to ClaimsController#show:
#
#   export async function getServerSideProps(ctx) {
#     const { id } = ctx.params;
#     const claim = await fetchClaim(id);
#     return { props: { claim } };
#   }
#
# In Rails: load the data in the controller action, set @claim, and the
# view will read it via the existing props plumbing.
```

If `@rails_view` is not set (non-rails-routes mode), still emit a similar block but referencing "the host controller" rather than a specific name.

### Files

| Path | Status | Scope |
|---|---|---|
| `lib/jsx_rosetta/ir/lowering.rb` | modify | New `extract_server_data_source(program)` scans the AST body for the export shapes above. Threads the result into `Component.new(...)` at lower-time. |
| `lib/jsx_rosetta/ir/types.rb` | modify | New `ServerDataSource` value type. New `server_data_source:` field on `Component`. |
| `lib/jsx_rosetta/backend/phlex.rb` | modify | New `render_server_data_source_todo(component)` helper. Prepended to the class output above any cva/module-constant prefix. |

### Specs

- `export async function getServerSideProps(ctx) { ... }` — function declaration form.
- `export const getServerSideProps = async (ctx) => { ... }` — const-arrow form.
- `export const getStaticProps = ...` — alternate hook name.
- Two hooks in the same file — only the first is captured (multi-hook is unusual and overlap is rare; the second still surfaces in module_bindings TODO).
- View emission prepends the TODO block with the right controller name.

## Verification

```bash
bundle exec rake                            # rspec + rubocop
bundle exec exe/jsx_rosetta pages-routes tmp/stress/phlex_out/reserv-web/pages \
  --ext .rb -o /tmp/slice4_routes.rb
ruby -c /tmp/slice4_routes.rb               # must succeed
bash tmp/run_phlex_stress.sh                # full corpus translate
ruby -c tmp/stress/phlex_out/**/*.rb 2>&1 | grep -v "Syntax OK" | head
```

Numbers to track:

- routes.rb line count (more lines from namespace blocks, comment headers).
- Page-component count translating cleanly (currently 82/82 emitted).
- `ruby -c` pass count (currently 1239/1239).
- Stress corpus: confirm no regressions on non-page files (B-series is page-router-specific).

## Out of scope (deferred or out of umbrella)

- HOC unwrapping (#1).
- Anchor / query-string preservation in href rewriter (#10).
- Slice C (`<form action>` + ViewComponent/RailsView `--rails-routes`) — separate slice in the umbrella.
- Translating Next.js `Link` props beyond `href` (`prefetch`, `replace`, etc.).
- Provider-component recognition inside `_app.tsx`. The wrapper stays as a ComponentInvocation TODO around `yield`; the host is expected to port providers to Rails initializers or Stimulus controllers by hand.

## Risks

- **B3 breaks downstream route helpers.** Any host code that already references `admin_users_show_path` after slice 1's `as:` addition will need to update to `admin_user_path`. Mitigation: note in CHANGELOG; the rename happens once.
- **B5 + B3 stacking gets visually busy.** Two nested `namespace` blocks in routes.rb (group + nested) is supported but unusual. Spec covers, but real corpora rarely hit it.
- **B1 captures large `getServerSideProps` bodies verbatim.** A 200-line server-side handler ends up as a 200-line comment block above the class. Acceptable: the TODO header is clear, and the alternative (silent drop) loses information. Long blocks are a code-review smell, not a translation bug.
- **B2 layout heuristic is approximate.** `_app.tsx` files that don't follow the standard `<Component {...pageProps} />` shape (e.g. ones that conditionally swap layouts based on `Component.getLayout`) won't emit a `yield`. Mitigation: fall back to emitting the entire body as a TODO with a note that the layout-yield wasn't detected, and let the user wire it.
- **B4 error pages aren't real Rails routes.** Some Rails apps wire errors via `public/404.html` instead of `config.exceptions_app`. The wiring comment block names both options.
