# Recipe 07 — Next.js navigation hooks

## Shape

```
# TODO: Next.js navigation hooks detected. None translate automatically.
# <guidance text>
#   <verbatim useRouter / usePathname / useSearchParams block>
```

## Status

**STUB.** Full recipe to be written.

## Action

**Sharpen** with route extraction.

For `useRouter().push("/path/[id]", ...)`:

```ruby
# TODO[nextjs:nav]: navigation — replace with Rails url helper.
#   Source: router.push("/foo/[id]"). Likely target: foo_path(id: <id>).
#   Confirm in config/routes.rb.
# Original:
#   <verbatim>
```

For `router.query.<key>` reads:

```ruby
# TODO[nextjs:query]: read of router.query.<key>. In a controller action,
#   this is params[:<key>]. If this component is rendered from a controller,
#   thread <key> as a prop.
# Original:
#   <verbatim>
```

For `usePathname()` / `useSearchParams()`: sharpen similarly with `request.path` / `params` mappings.

## When to escalate

- Programmatic navigation tied to async data loading (typically becomes a Turbo Stream response from a controller)
- Conditional routing that depends on client-side state
