# jsx_rosetta — Next.js filesystem routing → Rails routes/controllers/views

## Context

The Phlex backend emits `_page.rb` files preserving the source directory structure under `pages/` — including Next.js bracket conventions (`[id]`, `[[...extra]]`) and named segments. Visually inspecting `tmp/stress/phlex_out/reserv-web/pages/` confirms the tree mirrors a Rails route table: top-level files are entry routes, named subdirectories look like resource collections, `[id]/` segments are member routes, deeper nests are nested resources.

The gem already has a `Routes` module + `routes_script` backend, but those handle a **different** source: JSX `<Route path=… element={<X/>} />` declarative routes (React Router). The Next.js filesystem-routing case is unaddressed — generated Phlex pages currently land in `pages/...` without any `config/routes.rb`, controllers, or `app/views/` placement, so a user has to hand-wire the Rails side after translation.

Goal: ship a deterministic, filesystem-driven path from a Next.js `pages/` directory to a usable Rails skeleton. The directory tree is the source of truth; no JS parsing is required for routing alone.

## Slicing

Three slices, planned separately, landed in order:

1. **Slice 1 — routes only** *(this plan)*. Walk the source `pages/` tree, emit `config/routes.rb`. No file moves, no controllers, no class renames. New CLI subcommand `jsx_rosetta pages-routes`.

2. **Slice 2 — controllers + view-placement** *(separate plan after slice 1 lands)*. Emit `app/controllers/<resource>_controller.rb` skeletons. Hook into `translate` so Phlex pages land at `app/views/<controller>/<action>.rb` with class `Views::<Controller>::<Action> < Views::Base` per Phlex Rails convention.

3. **Slice 3 — `<Link>`/`href` rewrites to URL helpers** *(separate plan after slice 2)*. With route table from slice 1 in hand, the Phlex backend rewrites literal/simple-template hrefs (`<Link href="/claims/123">`, `<Link href={`/claims/${id}`}>`) into Rails helpers (`claim_path(123)`, `claim_path(id)`). Anything past simple template — dynamic compute, query strings, `router.push` in event handlers — stays verbatim with a TODO (handler bodies are preserved as raw JS in `IR::EventHandler` and rewriting them is the JS-to-Ruby translation territory the project avoids).

This plan covers slice 1 in full. Slices 2 and 3 are sketched at the end for context only — they get their own plan files when their predecessor ships.

## Slice 1 — design

### Input

Filesystem-only walker. Reads file paths, not contents.

- Input: a directory the user points at (typically `<repo>/pages/` or `<repo>/src/pages/`).
- File types scanned: `.tsx`, `.jsx` (and optionally `.ts`/`.js` if the user has a JS-only Next.js project; default to TSX/JSX, configurable via flag).
- No `JsxRosetta.parse` / `JsxRosetta.lower` — the route table is fully encoded in path shape. Parsing 80+ files just to read names that we already have from `Dir.glob` would burn ~30s of Node round-trips for zero added signal.
- Slice 2 will piggyback on the existing `translate` flow, where parse+lower already runs per file, so the AST/IR is "free" at that point.

### Path → Rails route mapping

Bracket segments translate to Rails params with camelCase → snake_case via `JsxRosetta::AST::Inflector.underscore`. `[providerSlug]` → `:provider_slug`, `[organizationId]` → `:organization_id`.

| Source path (relative to pages/) | Rails route line | Controller#action |
|---|---|---|
| `index.tsx` | `root to: "pages#index"` | PagesController#index |
| `<name>.tsx` (top-level, not `_*`) | `get "/<name>", to: "pages#<name>"` | PagesController#<name> |
| `<res>/index.tsx` | `get "/<res>", to: "<res>#index"` | <Res>Controller#index |
| `<res>/new.tsx` | `get "/<res>/new", to: "<res>#new"` | <Res>Controller#new |
| `<res>/[id].tsx` | `get "/<res>/:id", to: "<res>#show"` | <Res>Controller#show |
| `<res>/[id]/index.tsx` | `get "/<res>/:id", to: "<res>#show"` | (same — duplicate-route warning) |
| `<res>/[id]/edit.tsx` | `get "/<res>/:id/edit", to: "<res>#edit"` | <Res>Controller#edit |
| `<res>/[id]/<x>.tsx` | `get "/<res>/:id/<x>", to: "<res>#<x>"` | <Res>Controller#<x> |
| `<res>/[id]/[[...extra]].tsx` | `get "/<res>/:id(/*extra)", to: "<res>#show"` | <Res>Controller#show |
| `<res>/[id]/<sub>/[sub_id]/...` (deep) | nested params in path; controller = outermost named segment | <Res>Controller#<leaf-action> |
| `_app.tsx`, `_document.tsx` | **skipped**; commented in output as layout files | (none) |
| `_error.tsx`, `404.tsx`, `500.tsx` | **skipped**; commented as Rails error handlers (`config.exceptions_app`) | (none) |

### Controller-name selection rule

- Top-level file → `pages` controller.
- File inside a subdirectory → controller is the **first non-bracket segment** (the outermost named directory). For `policies/[providerSlug]/[policyId]/edit.tsx`, controller is `policies`; the rest of the path becomes URL params.
- Nested named dirs *between* the resource and the leaf — e.g., `workflows/[id]/versions/index.tsx` — get expressed as path segments, not separate controllers, in slice 1. Slice 2 may upgrade some of these to namespaces (`Workflows::Versions`) once we have the controller story figured out.

### Action-name selection rule

| Leaf filename | Inside one or more `[…]` dirs? | Action |
|---|---|---|
| `index.tsx` | no | `index` |
| `index.tsx` | yes | `show` |
| `new.tsx` | no | `new` |
| `edit.tsx` | yes | `edit` |
| `[id].tsx` (the bracket file *is* the leaf) | n/a | `show` |
| `[[...extra]].tsx` | n/a | `show` |
| any other `<name>.tsx` | * | `<name>` (snake_cased) |

### Output

A complete `config/routes.rb` — wrapped in `Rails.application.routes.draw do … end`, not a snippet. Sections:

1. Header comment: source dir, generation timestamp, gem version.
2. Skipped-files block at top, commented, with TODO markers pointing at Rails layout / error-handling counterparts.
3. Routes grouped by controller, alphabetized. One blank line between groups. Comment header per group (`# == accounts ==`).
4. Closing `end`.

The emitted file passes `ruby -c`. Suggested companion `rails generate controller …` invocations (matching the existing `routes_script` pattern) are commented out at the bottom — copy-paste-able but not run.

### Implementation

New module + files. Mirrors the layout of `lib/jsx_rosetta/routes.rb` (sibling to `Routes`, not nested inside it, because the two have unrelated inputs).

| Path | Status | Scope |
|---|---|---|
| `lib/jsx_rosetta/pages_routing.rb` | new | `Scanner`, `Route`, `Emitter`, ~150 lines |
| `lib/jsx_rosetta.rb` | modify | one new `require_relative "jsx_rosetta/pages_routing"` line |
| `lib/jsx_rosetta/cli.rb` | modify | new `when "pages-routes"` branch + `run_pages_routes` method + help text update |
| `lib/jsx_rosetta/ir/types.rb` | unchanged | no new IR types needed for slice 1 |

Internal shapes:

```ruby
module JsxRosetta
  module PagesRouting
    Route = Data.define(:rails_path, :controller, :action, :source_path)
    Skipped = Data.define(:source_path, :reason)

    module Scanner
      def self.scan(dir, extensions: %w[.tsx .jsx])
        # walks dir, returns [routes:, skipped:]
      end
    end

    module Emitter
      def self.emit(routes:, skipped:, source_dir:)
        # returns String (full routes.rb contents)
      end
    end
  end
end
```

### Existing utilities to reuse

- `JsxRosetta::AST::Inflector.underscore` — for camelCase → snake_case on param names and controller names (already does the right thing for `providerSlug` → `provider_slug`).
- The existing `RoutesScript` backend's output template (header comment style, `rails generate` invocation phrasing) — copy the style, don't share code, since their inputs differ. Match phrasing for consistency.

### Specs

Match the existing flat-spec convention (`spec/routes_spec.rb`, `spec/cli_spec.rb` are both single files, not directories).

| Path | Status | Coverage |
|---|---|---|
| `spec/pages_routing_spec.rb` | new | Scanner: each row of the mapping table (~15 examples). Emitter: ordering, grouping, comment headers, skipped-files block (~6 examples). Use `Dir.mktmpdir` + `FileUtils.touch` to build synthetic trees. |
| `spec/cli_spec.rb` | modify | New describe block for `pages-routes` subcommand (~3 examples: happy path, missing dir error, `-o` flag). |

Edge cases worth one spec each:
- Empty `pages/` dir → emit an empty `routes.rb` (with header comment) without crashing.
- `pages/` with only `_app.tsx`, `_document.tsx` → all-skipped output; route table empty.
- `pages/` with a single `index.tsx` → exactly one `root` line.
- Deep nesting (`pages/policies/[providerSlug]/[policyId]/edit.tsx`) → param order preserved, snake_case applied to both.
- `[...rest]` non-optional rest catch-all — not seen in the stress corpus; treat as `*rest` (no parens) and add one spec.

### CLI surface

```
jsx_rosetta pages-routes <pages-dir> [-o <path>] [--ext .tsx,.jsx,.ts,.js]
```

Defaults: `-o` writes to stdout if absent; `--ext` defaults to `.tsx,.jsx`. Help text updated in `print_help`.

### Verification

```bash
cd /home/sean/code/jsx_rosetta
bundle exec rspec spec/pages_routing_spec.rb spec/cli_spec.rb
bundle exec rubocop lib/jsx_rosetta/pages_routing.rb lib/jsx_rosetta/cli.rb spec/pages_routing_spec.rb
bundle exec rake # full default suite

# Round-trip against the stress corpus' page directory shape.
# (The stress run emits .rb files, but the bracket directory names
# carry the same Next.js shape — point the scanner at them with --ext .rb
# to confirm the path classifier handles real-world depth.)
bundle exec exe/jsx_rosetta pages-routes tmp/stress/phlex_out/reserv-web/pages \
  --ext .rb -o /tmp/routes.rb
ruby -c /tmp/routes.rb   # must succeed
wc -l /tmp/routes.rb     # ballpark: ~100 route lines for ~80 leaf files
```

Spot-check 5 routes by hand against the original `pages/...` paths to confirm controller + action selection.

## Slice 2 sketch (separate plan, after slice 1)

Coupled changes — best landed together so the controller's `render` call references the relocated view class:

1. **Controller emission**: for each unique controller from slice 1's route table, emit `app/controllers/<controller>_controller.rb` with one empty `def <action>; end` per action. Add a `before_action` TODO comment listing the URL params (`:id`, `:provider_slug`, etc.). Skip emission if the controller file already exists (never clobber user code).

2. **View relocation + class rename**: change the Phlex backend so when it knows it's running with a route map (via a `--rails-routes <pages-dir>` flag or a `JsxRosetta.translate` option), it routes each page file to `app/views/<controller>/<action>.rb` instead of preserving the source directory shape, and renames the class from `<Foo>Page` to `Views::<Controller>::<Action>` with parent `Views::Base`. The Phlex Rails docs ([phlex.fun/rails/layouts](https://www.phlex.fun/rails/layouts)) confirm `Views::Articles::Index < Views::Base` (which inherits from `Phlex::HTML`) at `app/views/articles/index.rb` is the canonical shape.

Deferred to that plan: action-name collisions, namespace nesting (`pages/admin/users/...` → `Admin::UsersController`?), the `_app.tsx`/`_document.tsx` → application-layout component handling, optional detection of `getServerSideProps` to mark controller actions as needing data-fetching TODOs (the only place AST/IR meaningfully helps).

## Slice 3 sketch (separate plan, after slice 2)

URL-helper rewrite in the Phlex backend:

- `<Link href="/claims/123">` → `link_to "...", claim_path(123)` when `/claims/:id` is in the route table.
- `<Link href={`/claims/${claim.id}`}>` → match the template literal's static segments against the route table; rewrite if exactly one route matches with one `:id`-shaped hole.
- `<Link href={someComputed}>` → leave verbatim + TODO.
- `router.push("/claims/...")` in event handlers — **skipped** (handler bodies are preserved JS in `IR::EventHandler`; rewriting requires a JS-AST pass which conflicts with the "no speculative JS-to-Ruby translation" project rule).

Practicality: literal & simple-template href rewrites are deterministic and high-value (every `<Link>` to a known resource gets idiomatic Rails). Anything past that stays verbatim. Worth doing once the route table is real.

## Out of scope for slice 1

- Controller skeletons (slice 2).
- View relocation / rename (slice 2).
- `<Link>` / `href` → URL helper rewrites (slice 3).
- `getServerSideProps` / `getStaticProps` detection — would require AST parsing per file. Belongs in slice 2 if at all.
- Route groups like `(group)/` — none in the stress corpus; defer until encountered.
- Application-layout / error-handler emission for `_app.tsx`, `_document.tsx`, `_error.tsx` — slice 1 just lists them as TODO comments at the top of the emitted `routes.rb`.
- Sharing infrastructure with the existing `RoutesScript` backend — they have different inputs and different output shapes; deduplicate later if both grow.

## Risks

- **Action name collisions across files.** Two leaves in the same controller may both want the same action name (e.g., a `[id]/edit.tsx` and a `new_edit.tsx` both wanting `edit`). Scanner detects, emits a duplicate-route warning comment in the output, picks one and suffixes the other with `_2`. Spec covers this.
- **Deeply-nested resources don't fit Rails REST naming.** `pages/policies/[providerSlug]/[policyId]/edit.tsx` becomes `policies#edit` with two URL params — semantically right, but a Rails dev might expect a `PoliciesProvidersPoliciesController`. Slice 1 deliberately punts on this — emit the flat route, let the user reshape in slice 2 if they want.
- **Files outside the pages root.** If the user points at a parent of `pages/`, the scanner will treat every `.tsx` file as a top-level page. Scanner errors out if `<dir>` doesn't end in `pages` (or contain a `pages/` subdir) unless `--allow-any-dir` is passed.
