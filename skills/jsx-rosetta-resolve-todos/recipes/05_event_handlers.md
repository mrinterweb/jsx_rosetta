# Recipe 05 — Event handlers

## Shape

A `handle_*` private method stub with verbatim JS in a TODO:

```ruby
def handle_click
  # TODO: translate the original JSX `onClick` handler:
  #   {
  #     <verbatim JS body>
  #   }
end
```

## Status

**Documented intentions** — recipe describes the recommended LLM-driven action; no backing tooling yet. The classification table below is usable by an agent today.

## Action

**Sharpen** by classifying the handler's body, then prescribe a target:

| Body shape | Classification | Target |
|---|---|---|
| Calls a state setter (`setX(...)`) | behavioral UI state | Stimulus action: `data-action="<event>->controller#<method>"`, body becomes JS in the Stimulus controller |
| Calls a mutation / fetch | data mutation | Form submit to a Rails action; remove the handler, wire the form's `action=` |
| Calls `router.push(...)` | navigation | Plain `<a>` or `link_to`; remove the handler |
| Local computation only, no I/O | behavioral | Stimulus action |
| Mixed | manual | Escalate with a note |

Sharpened TODO sits on the `handle_*` method stub:

```ruby
def handle_click
  # TODO[event_handler:behavioral]: setIsOpen toggle. Convert to Stimulus action
  #   `data-action="click->dropdown#toggle"`; body moves to dropdown_controller.js.
  # Original:
  #   <verbatim JS body>
end
```

## Why classification matters

Behavioral handlers translate to Stimulus actions; data-mutation handlers translate to form submits. These are very different Rails-side surfaces — the wrong target buys nothing and may hide a real architectural choice the human needs to make.
