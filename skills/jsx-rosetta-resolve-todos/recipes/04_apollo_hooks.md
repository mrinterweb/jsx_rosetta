# Recipe 04 — Apollo data-fetching hooks

## Shape

```
# TODO: Apollo data-fetching hooks detected. None translate automatically.
# <guidance text>
#   <verbatim useQuery / useMutation block>
```

## Status

**Documented intentions** — recipe describes the recommended LLM-driven action; no backing tooling yet. The sharpen template + extraction rule below is usable by an agent today, but the GraphQL operation parsing has only been spec'd, not implemented.

## Action

**Sharpen.** Recipe is constant: Apollo fetches → Rails controller fetches → component receives data as a prop.

Extract the GraphQL operation name and variables from the dumped block, then emit:

```ruby
# TODO[apollo]: controller fetch — <Operation> with vars { <var1>, <var2> }.
#   In <controller>#<action>, set @<name> = <ResolverClass>.call(<vars>) and
#   pass to this component as <prop_name>: @<name>.
# Original:
#   <verbatim hook>
```

Look up `target_app_conventions.yml` for the consuming repo's resolver/service path. If absent, mark `<TBD: see target_app_conventions.yml>` rather than guessing.

## When to escalate

- `useMutation` blocks — these typically map to form submits, but the form's HTML structure may need restructuring; sharpen with the operation name and let a human design the form.
- Optimistic updates / cache writes — these are React-state-of-the-world dependent and don't have a 1:1 Hotwire mapping.
