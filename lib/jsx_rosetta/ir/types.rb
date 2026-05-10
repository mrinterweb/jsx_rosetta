# frozen_string_literal: true

module JsxRosetta
  module IR
    # Marker module included by every IR node type. Lets backends and
    # tests sanity-check that something is an IR value (`is_a?(IR::Node)`).
    module Node
    end

    # A translated component definition. The root of a lowered IR tree.
    #
    # name           : String — component name as it appears in JSX (e.g. "Button").
    # props          : [Prop]
    # body           : Node — usually an Element or Fragment.
    # rest_prop_name : String | nil — name of a rest-destructured prop
    #                  (`function X({ a, ...rest })`). When non-nil, the
    #                  backend should generate a `**rest` initializer kwarg
    #                  and make it available via `@rest_prop_name`.
    # local_bindings : [LocalBinding] — non-JSX local `const` bindings inside
    #                  the component body. Backends typically render these as
    #                  a TODO comment block since arbitrary JS-to-Ruby
    #                  translation isn't attempted.
    Component = Data.define(:name, :props, :body, :rest_prop_name, :local_bindings) do
      include Node
    end

    # A non-JSX local binding declared inside the component body
    # (`const date = parseISO(dateString)`). The verbatim source is
    # preserved so the human reviewer can translate it.
    #
    # name   : String
    # source : String — verbatim JS of the entire VariableDeclaration statement.
    LocalBinding = Data.define(:name, :source) do
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

    # A spread attribute: `{...rest}` in JSX. The expression is preserved
    # verbatim; backends emit it as `**<expression>` or equivalent.
    #
    # expression : String — verbatim JS source of the spread argument
    #              (typically a single identifier, sometimes a member chain).
    SpreadAttribute = Data.define(:expression) do
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

    # A decomposed className expression — the result of recognizing a
    # `cn(...)` / `clsx(...)` / `classnames(...)` call at lowering time.
    # Each segment is one of:
    #   String                 — literal class chunk like "btn btn-primary"
    #   Interpolation          — variable reference (translated by backend)
    #   ConditionalSegment     — `{ "active": isActive }` style entry
    ClassList = Data.define(:segments) do
      include Node
    end

    # A conditional class entry (`{ "active": isActive }` from cn-style
    # helpers). Renders the class_name when the condition is truthy.
    #
    # class_name : String — literal class string to emit when condition is truthy.
    # condition  : Interpolation — verbatim JS source of the condition.
    ConditionalSegment = Data.define(:class_name, :condition) do
      include Node
    end

    # A decomposed inline-style expression (JSX `style={{ ... }}`).
    #
    # declarations : [StyleDeclaration] — one per property in the source order
    Style = Data.define(:declarations) do
      include Node
    end

    # A single CSS property/value pair, with the property already converted
    # from JSX camelCase to CSS kebab-case.
    #
    # property : String — kebab-case CSS property (e.g. "font-size")
    # value    : String | Interpolation — String for literal CSS values
    #            already quoted ready for output, Interpolation for runtime
    #            values to be ERB-interpolated.
    StyleDeclaration = Data.define(:property, :value) do
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

    # A comment lifted from JSX (`{/* … */}`). Backends decide how to
    # surface it (ERB `<%# … %>`, HTML `<!-- -->`, etc.).
    #
    # text : String — comment body verbatim, including any leading/trailing
    #                 whitespace from the JSX source.
    Comment = Data.define(:text) do
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
