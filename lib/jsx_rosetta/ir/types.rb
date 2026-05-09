# frozen_string_literal: true

module JsxRosetta
  module IR
    # Marker module included by every IR node type. Lets backends and
    # tests sanity-check that something is an IR value (`is_a?(IR::Node)`).
    module Node
    end

    # A translated component definition. The root of a lowered IR tree.
    #
    # name  : String — component name as it appears in JSX (e.g. "Button").
    # props : [Prop]
    # body  : Node — usually an Element or Fragment.
    Component = Data.define(:name, :props, :body) do
      include Node
    end

    # A component prop, possibly with a default value.
    #
    # name    : String
    # default : Interpolation | nil
    Prop = Data.define(:name, :default) do
      include Node
    end

    # An HTML element (lowercase tag name, no member-expression form).
    #
    # tag        : String — "button", "div", etc.
    # attributes : [Attribute | StyleBinding] (and EventBinding once Phase 4 lands)
    # children   : [Element | ComponentInvocation | Text | Interpolation | Fragment]
    Element = Data.define(:tag, :attributes, :children) do
      include Node
    end

    # A component invocation. Distinct from Element so backends can render
    # it as `render Component.new(...)` rather than as a raw HTML tag.
    #
    # name     : String — "Button", "Foo.Bar", etc.
    # props    : [Attribute | StyleBinding]
    # children : [Element | ComponentInvocation | Text | Interpolation | Fragment]
    ComponentInvocation = Data.define(:name, :props, :children) do
      include Node
    end

    # A name/value pair on an Element or ComponentInvocation.
    #
    # name  : String
    # value : String | true | Interpolation
    #         - String: literal value from a JSX string-literal attribute
    #           (e.g. `type="button"` → value: "button").
    #         - true: boolean attribute with no value (e.g. `<input disabled />`).
    #         - Interpolation: expression-container value (e.g. `href={url}`).
    Attribute = Data.define(:name, :value) do
      include Node
    end

    # A class-binding expression — what JSX expresses as `className={...}`.
    #
    # expression : String — verbatim JS source of the className value
    #                       (literal string in quotes, template literal,
    #                       call to `cn(...)`, etc.). Decomposition into
    #                       individual classes/conditionals is deferred.
    StyleBinding = Data.define(:expression) do
      include Node
    end

    # An opaque JS expression embedded in JSX (between curlies). The
    # expression text is preserved verbatim so the backend can emit it
    # into `<%= %>` (or its target equivalent) for human review.
    #
    # expression : String — verbatim JS source.
    Interpolation = Data.define(:expression) do
      include Node
    end

    # A literal text node.
    #
    # value : String
    Text = Data.define(:value) do
      include Node
    end

    # A JSX fragment (`<>...</>`).
    #
    # children : [Element | ComponentInvocation | Text | Interpolation | Fragment]
    Fragment = Data.define(:children) do
      include Node
    end

    # A conditional render. Lowered from any of:
    #   {cond && <X />}
    #   {cond ? <X /> : null}
    #   {cond ? <X /> : <Y />}
    #
    # test       : Interpolation — verbatim JS source of the condition.
    # consequent : Node — what to render when test is truthy.
    # alternate  : Node | nil — what to render otherwise (nil for `cond &&`
    #              or for `cond ? X : null`).
    Conditional = Data.define(:test, :consequent, :alternate) do
      include Node
    end

    # A content slot. Backends decide how to realize it (ViewComponent's
    # `content` for the default slot, named renders_one slots for others).
    #
    # name : String — "children" for the default slot, or a prop name.
    Slot = Data.define(:name) do
      include Node
    end

    # An event handler binding. Lowered from a JSX attribute named
    # `on<Event>` whose value is an expression container.
    #
    # event   : String — lowercased DOM event name ("click", "change",
    #           "mouseenter").
    # handler : Interpolation — the JS expression bound to the event,
    #           verbatim. For ViewComponent + Stimulus, the caller is
    #           expected to supply a Stimulus action descriptor string
    #           (e.g. "click->my-controller#handleClick"); the component
    #           just renders it through.
    EventBinding = Data.define(:event, :handler) do
      include Node
    end

    # A list-rendering loop. Lowered from a JSX expression of the form:
    #   {items.map((item) => <X />)}
    #   {items.map((item, index) => <X />)}
    # plus the arrow-with-block form `(item) => { return <X />; }`.
    #
    # iterable      : Interpolation — verbatim source of the iterable
    #                 expression (e.g. "items", "todos.filter(...)").
    # item_binding  : String — name of the item parameter, in original
    #                 camelCase. Backends snake_case as needed.
    # index_binding : String | nil — name of the index parameter, if present.
    # body          : Node — the lowered IR node rendered for each iteration.
    Loop = Data.define(:iterable, :item_binding, :index_binding, :body) do
      include Node
    end
  end
end
