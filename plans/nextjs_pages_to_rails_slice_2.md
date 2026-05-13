# jsx_rosetta — slice 2: controller skeletons + Phlex view placement

Builds on slice 1 (`pages-routes` → routes.rb). Slice 1 produced the route table; this slice consumes it to (a) emit controller files matching the route table and (b) reshape Phlex backend output to match Rails view conventions.

Parent plan: `plans/nextjs_pages_to_rails.md` (slice 2 sketch section).

## Two coupled deliverables

These ship together because the controller's `render` (implicit) references the view class that view-placement renames.

### A. Controller emission

For each unique `controller` in the route table:

- Emit `app/controllers/<controller>_controller.rb`.
- One empty `def <action>; end` per route in that controller, alphabetized.
- Comment above each action listing URL params extracted from the matching `rails_path` (e.g. `# params: :id, :provider_slug`).
- Skip emission entirely if the file already exists on disk (never clobber user code — emit a stderr note).
- Parent class: `ApplicationController` (Rails convention; user is expected to have it).

### B. Phlex view placement

New backend option `rails_view:` on `Backend::Phlex`. When set to a route entry (responding to `controller` and `action`):

- File path: `<controller>/<action>.rb` (slot under `app/views/` at the CLI level).
- Class name: `Views::<ControllerCamel>::<ActionCamel>`.
- Parent class: `Views::Base` (user-defined per Phlex Rails convention; reference [phlex.fun/rails/layouts](https://www.phlex.fun/rails/layouts)).

The existing `suffix:` / `namespace:` Phlex options are mutually exclusive with `rails_view:` — error out if combined.

The page-aware `effective_suffix_for` / `page?` helpers added in v0.5.x stop applying when `rails_view:` is set — the Rails convention takes precedence.

## CLI surface

### Extended `pages-routes`

```
jsx_rosetta pages-routes <pages-dir> [-o routes.rb] [--controllers DIR] \
                                     [--ext .tsx,.jsx] [--allow-any-dir]
```

`--controllers DIR` is independent of `-o`. When set:

- Writes one `<controller>_controller.rb` per controller into `DIR`.
- Prints `wrote <path>` lines to stdout.
- Skips files that already exist; prints `skipped <path> (exists)`.

### Extended `translate`

```
jsx_rosetta translate <file.tsx> --as=phlex --rails-routes <pages-dir> -o <views-dir>
```

When `--rails-routes` is set:

- Scans `<pages-dir>` to build a route lookup once.
- Resolves `<file>`'s path relative to `<pages-dir>`. Error if the file is not under it.
- Looks up the route by source path. Error if the file is not represented in the table (e.g., skipped `_app.tsx`).
- Passes `rails_view: Route` as a Phlex backend option.
- Output lands at `<views-dir>/<controller>/<action>.rb`.

`--rails-routes` is invalid without `--as=phlex` (ViewComponent + RailsView backends are out of scope for this slice).

`--rails-routes` is invalid combined with `--phlex-suffix` / `--phlex-namespace`.

## Implementation

| Path | Status | Scope |
|---|---|---|
| `lib/jsx_rosetta/pages_routing.rb` | modify | New `Emitter.emit_controllers(routes:)` returning `[File-like]`. Action-name camelization helpers. |
| `lib/jsx_rosetta/backend/phlex.rb` | modify | Accept `rails_view:` option. Override `class_name`, parent class, and file path when set. |
| `lib/jsx_rosetta.rb` | modify | Surface `rails_view:` in `backend_options.slice` allowlist for the Phlex backend. |
| `lib/jsx_rosetta/cli.rb` | modify | `--controllers DIR` on pages-routes; `--rails-routes DIR` on translate. |

### URL-param extraction for controller comments

From a `rails_path` like `/policies/:provider_slug/:policy_id/edit`, strip everything that isn't a `:param` token: `[:provider_slug, :policy_id]`. Catch-all params (`*rest`, `(/*extra)`) included as `*rest`-style entries. Emitted as `# params: :provider_slug, :policy_id` above the action.

### Class-name camelization

`AST::Inflector.camelize` returns lowerCamelCase. For class names this slice needs UpperCamelCase. Add `AST::Inflector.upper_camelize` (or inline `parts.map(&:capitalize).join`) — pick whichever keeps the inflector module focused.

## Specs

| Path | Status | Coverage |
|---|---|---|
| `spec/pages_routing_spec.rb` | modify | `Emitter.emit_controllers` shape, action ordering, param comments, skip-on-exists is a CLI concern not module concern (covered in cli_spec). |
| `spec/backend/phlex_spec.rb` | modify | `rails_view:` option overrides class + parent + path; mutual-exclusion errors with `suffix:` / `namespace:`. |
| `spec/cli_spec.rb` | modify | `pages-routes --controllers DIR`: writes per-controller files, skips existing; `translate --rails-routes <pages-dir>`: writes view to `<controller>/<action>.rb`, errors when file is outside pages-dir, errors when file is skipped. |

## Verification

```bash
cd /home/sean/code/jsx_rosetta
bundle exec rake

# Round-trip a real page through the new pipeline.
ruby -Ilib exe/jsx_rosetta pages-routes tmp/stress/phlex_out/reserv-web/pages \
  --ext .rb -o /tmp/routes.rb --controllers /tmp/controllers
ls /tmp/controllers
ruby -c /tmp/controllers/*.rb
```

Spot-check a few generated controllers against the route table to confirm action lists, param comments, and class names.

## Out of scope (deferred to future slices or punted)

- Namespace nesting (`pages/admin/users/...` → `Admin::UsersController`). Keep flat controllers for slice 2; revisit if it bites.
- `_app.tsx` / `_document.tsx` → application-layout class. The skipped-files block in slice 1's routes.rb already flags these.
- `getServerSideProps` / `getStaticProps` detection — requires AST per file. Not in slice 2.
- Action-name collisions across files in the same controller — slice 1 already dedupes identical routes; cross-path collisions remain rare. Punt to slice 3 or later.
- `--rails-routes` for non-Phlex backends — slice 3+ if needed.

## Risks

- **`Views::Base` not defined.** User must add it themselves per Phlex Rails docs. We emit a one-line `# TODO: ensure app/views/base.rb defines Views::Base < Phlex::HTML` comment at the top of each view file. No autogeneration of `Views::Base` — out of scope.
- **Controller file already exists.** Slice 2 skips with a stderr note rather than clobbering. Risks: user may not realize their controller is out of sync with the new routes. Mitigation: stderr message lists which actions the routes.rb expects so they can reconcile.
- **`ApplicationController` missing.** Same as above — emit referencing it; user wires up.
