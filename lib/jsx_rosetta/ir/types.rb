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
  end
end
