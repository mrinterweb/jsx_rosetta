# jsx_rosetta — slice 3: `<Link>` / `href` → Rails URL helpers

Builds on slices 1 (`pages-routes` → routes.rb) and 2 (controller skeletons + Phlex view placement). With the route table now available end-to-end through the `--rails-routes` flag, the Phlex backend can rewrite literal/simple-template URLs into matching Rails URL helpers.

Parent plan: `plans/nextjs_pages_to_rails.md` (slice 3 sketch).

## What gets rewritten

Only the `href` (or `to`) attribute on tags whose name is `a`, `Link`, `NavLink`, or `RouterLink`:

| Source | Rewritten to | Notes |
|---|---|---|
| `<a href="/accounts">` | `a(href: accounts_path)` | exact path match against route table |
| `<Link href="/accounts/123">` | `Link(href: account_path(123))` | numeric literals pass through as integer |
| `<Link href={`/accounts/${id}`}>` | `Link(href: account_path(id))` | single `:id`-shaped hole matched against an identifier or member expression |
| `<Link href={`/policies/${slug}/${policyId}/edit`}>` | `Link(href: edit_policy_path(slug, policy_id))` | multi-param simple template |
| `<Link href={someComputed}>` | unchanged + `# TODO:` | not deterministic |
| `<a href="https://external.example">` | unchanged | external URL — absolute scheme |
| `<a href="#anchor">` | unchanged | fragment-only |
| `router.push("/foo")` in handlers | unchanged | handler bodies are preserved JS (`IR::EventHandler`) — out of scope per project rule against speculative JS-to-Ruby translation |

## URL helper naming

Helpers and `as:` names are derived from `(controller, action, rails_path)` by a single function so slice 1's routes.rb and slice 3's rewrites stay paired:

| Controller / action / path | `as:` token | Helper |
|---|---|---|
| `(pages, index, "/")` | `:root` | `root_path` |
| `(accounts, index, _)` | `:accounts` | `accounts_path` |
| `(accounts, show, _)` | `:account` | `account_path(*params)` |
| `(accounts, new, _)` | `:new_account` | `new_account_path` |
| `(accounts, edit, _)` | `:edit_account` | `edit_account_path(*params)` |
| `(accounts, <other>, _)` | `:accounts_<other>` | `accounts_<other>_path(*params)` |

Singularization uses a small new `AST::Inflector.singularize`:
- `accounts` → `account`, `policies` → `policy`, `boxes` → `box`, `dishes` → `dish`, `houses` → `house`.
- Irregular plurals (`children`, `people`) are returned as-is — the user can fix the `as:` in routes.rb and re-run translate if needed.

## Slice 1 routes.rb change

`Emitter.route_line` adds `, as: :<name>` to each route line. This is a **behavior change** for the existing slice 1 output, so the slice 1 specs are updated alongside the new slice 3 specs. `root` route stays as `root to: "pages#index"` (Rails always names that `root`).

## Implementation

| Path | Status | Scope |
|---|---|---|
| `lib/jsx_rosetta/ast/inflector.rb` | modify | New `.singularize` (simple `ies`/`ses`/`s` rules). |
| `lib/jsx_rosetta/pages_routing.rb` | modify | New `Naming` module + `HrefRewriter` class. `Emitter.route_line` adds `as:`. |
| `lib/jsx_rosetta/backend/phlex.rb` | modify | New `route_table:` initializer kwarg. Thread `tag:` through `format_attributes` → `attribute_value_to_ruby`. Add the rewrite path. |
| `lib/jsx_rosetta.rb` | modify | Allowlist `route_table:` in the Phlex backend options slice. |
| `lib/jsx_rosetta/cli.rb` | modify | `resolve_rails_view_route!` also captures the full route table and forwards it via `options[:route_table]`. |

## HrefRewriter

```ruby
module JsxRosetta
  module PagesRouting
    class HrefRewriter
      def initialize(routes)
        # Builds an internal index keyed by (segment-shape) → route.
      end

      # value: a String (verbatim path), or { kind: :template, literal_segments: [...], holes: [ruby_expr, ...] }
      # Returns: a Ruby source string (e.g. "account_path(id)") or nil.
      def rewrite(value)
      end
    end
  end
end
```

Matching algorithm:
- Split both the input path and each route's `rails_path` by `/`.
- For each route, walk segments together: literal must equal, `:foo`/`(/*foo)`/`*foo` consumes the corresponding input segment(s).
- A single route must match (no ambiguity) — if multiple match, return nil (bail to verbatim + TODO).
- For literal input, the consumed segment value becomes a Ruby integer literal if `\A-?\d+\z`, else a Ruby string literal.
- For template input, the consumed segment value is the corresponding hole's Ruby expression.

## Phlex backend wiring

`@route_table` and `@href_rewriter` are stored on the backend instance during `initialize`. The `tag:` kwarg is plumbed through `format_attributes` → `append_attribute_part` → `phlex_attribute_part` → `plain_attribute_part` → `attribute_value_to_ruby`.

`attribute_value_to_ruby` short-circuits when (a) `@href_rewriter` is set, (b) tag is link-shaped (`a`, `Link`, `NavLink`, `RouterLink`), (c) name is `href` or `to`, (d) the value is a String or IR::Interpolation containing a string/template literal. The rewriter returns Ruby; otherwise we fall through to the existing behavior unchanged.

## Specs

- `spec/ast/inflector_spec.rb` (or wherever inflector specs live): `.singularize` table.
- `spec/pages_routing_spec.rb`: `Naming` table + `HrefRewriter` (literal match, template match, ambiguity, external/absent → nil) + slice 1 `Emitter` updates (`as:` lines).
- `spec/backend/phlex_spec.rb`: end-to-end Phlex `route_table:` test cases.
- `spec/cli_spec.rb`: `translate --rails-routes` produces a view with rewritten hrefs.

## Verification

```bash
cd /home/sean/code/jsx_rosetta
bundle exec rake

# Round-trip
ruby -Ilib exe/jsx_rosetta pages-routes tmp/stress/phlex_out/reserv-web/pages \
  --ext .rb -o /tmp/r3/routes.rb
grep -c 'as: :' /tmp/r3/routes.rb  # expect ~82 lines

# Synthetic href test
# (TSX with literal + template hrefs, translate with --rails-routes,
#  inspect the emitted view for `*_path` calls.)
```

## Out of scope

- Rewriting `href` on tags other than `a`/`Link`/`NavLink`/`RouterLink`.
- `<form action="/post">`-style action rewrites.
- `router.push("/x")` inside event handler bodies — preserved verbatim per project rule.
- Re-running `pages-routes` automatically when `translate` is invoked — user must keep their routes.rb in sync (the route table is scanned each `translate` call; only the routes.rb file on disk lags if the user doesn't re-run pages-routes).
- Anchor / query-string fragments. A path like `"/accounts#tab=details"` is left verbatim.
- Multi-route disambiguation by HTTP method (we only emit GET routes anyway).

## Risks

- **Slice 1 `as:` change is a breaking diff for any existing routes.rb consumers.** Mitigated by updating the slice 1 specs and including the change in the same commit so the gem's behavior is consistent.
- **Bad singularization** (e.g. `mice` → `mic`). Mitigated by emitting a TODO comment above the view file the first time a non-trivial helper is used, listing the helper names so the user can compare against their routes.rb.
- **False matches.** If the user has `/accounts` and `/accounts_list`, a literal `/accounts_list` would not match `/accounts` (segment equality), so this is safe. The bigger risk: a template literal `/foo/${x}` where multiple routes have `/foo/:id`-shapes — slice 3 bails (returns nil) on ambiguity.
