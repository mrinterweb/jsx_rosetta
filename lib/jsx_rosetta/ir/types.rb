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
    # local_binding_names : [String] — flat list of all names bound by the
    #                  component body (destructure patterns, hook tuples,
    #                  ordinary const bindings). Backends pass this into the
    #                  ExpressionTranslator so an identifier reference like
    #                  `count` resolves to a `nil` placeholder instead of
    #                  a bare unresolved snake_case identifier that NameErrors
    #                  at render time. Includes hook destructures (e.g.
    #                  `open` and `setOpen` from `useState`) even though
    #                  those names don't appear in `local_bindings`.
    # stimulus_methods : [StimulusMethod] — event handlers extracted from
    #                  inline arrows / const-bound arrows used in onX={...}.
    #                  When non-empty, backends should emit a sibling
    #                  Stimulus controller file alongside the .rb/.erb pair.
    # react_hooks    : [ReactHookCall] — every recognized hook invocation
    #                  in the component body, regardless of library.
    #                  Includes React's built-in hooks (useState, useEffect,
    #                  useRef, useContext, useMemo, useCallback, useReducer,
    #                  useImperativeHandle, useLayoutEffect), Apollo hooks
    #                  (useQuery, useMutation, useLazyQuery, useSubscription,
    #                  useApolloClient), and Next.js navigation hooks
    #                  (useRouter, usePathname, useSearchParams, useParams,
    #                  useSelectedLayoutSegment(s)). Each call carries a
    #                  `library` tag so backends can group them and emit a
    #                  library-specific TODO pointing at the right Rails
    #                  analog (Stimulus/server-render for React; controller
    #                  fetch for Apollo; request.path/params for Next.js).
    # module_bindings : [LocalBinding] — top-level `const`/`let` declarations
    #                  outside the component function that aren't themselves
    #                  components. Captured so backends can either translate
    #                  to Ruby constants (literal initializers) or surface
    #                  as a TODO comment block before the class definition.
    #                  Without this capture, references to module-level
    #                  constants from inside the JSX silently drop and
    #                  produce unbacked snake_case references at render time.
    # module_imports : [ModuleImport] — top-level `import` declarations.
    #                  Backends thread the imported names into the
    #                  ExpressionTranslator so any expression-context
    #                  reference to an import (e.g. `styles.listContainer`
    #                  from `import styles from "./X.module.css"`, or
    #                  `AlertStatusEnum.Pending` from a TS enum import)
    #                  bails out to a TODO instead of snake-casing to a
    #                  bare identifier that NameErrors at render time.
    # render_methods : [RenderMethod] — local arrow bindings that return JSX
    #                  and are invoked from the JSX body (`const renderHeader
    #                  = () => <div/>; ... {renderHeader()}`). Backends emit
    #                  each as a private method on the generated class and
    #                  reference it from a LocalRenderCall at the use site.
    # mode  : Symbol — `:view` for a normal Phlex/ViewComponent component
    #         whose body is rendered as JSX (the default); `:data_factory`
    #         for column-descriptor / option-list modules whose top-level
    #         export is a function returning an array of object literals.
    #         When `:data_factory`, the backend emits a snake_case method
    #         that returns the translated data, instead of `view_template`.
    #         JSX inside object properties still extracts to private
    #         methods on the class via the IR::Lambda path.
    Component = Data.define(:name, :props, :body, :rest_prop_name,
                            :local_bindings, :local_binding_names,
                            :module_bindings, :module_imports,
                            :stimulus_methods, :react_hooks,
                            :render_methods, :mode) do
      include Node
    end

    # A top-level `import` declaration. Captured at lowering time so the
    # ExpressionTranslator can recognize use-site references and bail out
    # to a TODO instead of emitting a bare snake_case identifier that
    # NameErrors at render time.
    #
    # name   : String — the local binding name (the side the source uses
    #          to reference the imported value). For `import { foo as bar }`
    #          this is "bar"; for `import * as styles` this is "styles";
    #          for `import Default` this is "Default".
    # source : String — the module specifier verbatim (e.g. "./styles.module.css",
    #          "@apollo/client", "react"). Lets backends apply per-source
    #          policy later (e.g. always strip `*.module.css` references).
    # kind   : Symbol — :default | :named | :namespace.
    ModuleImport = Data.define(:name, :source, :kind) do
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

    # A hook invocation detected in the component body. Covers React's
    # built-in hooks plus framework hooks we recognize (Apollo's `useQuery`/
    # `useMutation`/etc., Next.js's `useRouter`/`usePathname`/etc.).
    # Surfaced separately from local_bindings so backends can emit a more
    # specific TODO pointing at the Rails equivalent for each library,
    # instead of a generic "translate this JS".
    #
    # hook      : String — hook function name (`"useState"`, `"useQuery"`, …)
    # source    : String — verbatim JS of the entire statement.
    # library   : Symbol — `:react`, `:apollo`, or `:next_js`. Backends
    #             group hooks by library and emit one TODO block per group,
    #             since each library maps to a different Rails analog.
    # operation : String | nil — for Apollo hooks called with a bare-Identifier
    #             first argument (`useQuery(GET_USERS_QUERY, …)`), the
    #             captured operation name. nil when the first argument is
    #             not a simple Identifier, or when the hook isn't Apollo.
    #             Backends echo it in the TODO so the reviewer can match
    #             the operation back to its GraphQL document and to the
    #             Rails controller / model fetch it should become.
    ReactHookCall = Data.define(:hook, :source, :library, :operation) do
      include Node
    end

    # A component prop, possibly with a default value.
    #
    # name       : String — the prop name on the parent (e.g. "data-testid").
    # default    : Interpolation | nil
    # alias_name : String | nil — the local binding name inside the body when
    #              the destructure renames it (`"data-testid": dataTestId`).
    #              Use sites of the alias resolve to the prop's ivar.
    Prop = Data.define(:name, :default, :alias_name) do
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

    # An event handler routed through a generated Stimulus controller.
    #
    # event       : String — lowercased DOM event name.
    # method_name : String — Stimulus controller method (camelCase per
    #               Stimulus convention).
    StimulusBinding = Data.define(:event, :method_name) do
      include Node
    end

    # A flat list of React Router routes parsed from a router file.
    # Distinct from Component — RouteTree is the top-level result of
    # `JsxRosetta::Routes.lower(file)`, not part of a translated component.
    #
    # routes : [RouteEntry]
    RouteTree = Data.define(:routes) do
      include Node
    end

    # A single React Router route entry.
    #
    # path         : String — the JSX path attribute verbatim (e.g. "/posts/:id").
    # element_name : String — the JSX element name from element={<X />}
    #                (e.g. "PostShow"). Member-expression forms ("Layout.Index")
    #                are flattened to the rightmost name.
    RouteEntry = Data.define(:path, :element_name) do
      include Node
    end

    # A handler method to be emitted on the generated Stimulus controller.
    # Body translation is deferred to the human reviewer; we preserve the
    # original JS body verbatim.
    #
    # name          : String — camelCase Stimulus method name (uniquified
    #                 when two handlers collide on the same base name).
    # body_source   : String — verbatim JS body (the entire arrow function
    #                 or the function expression body), preserved as a
    #                 comment in the emitted controller skeleton.
    # original_name : String — the requested base name before uniquification.
    #                 Equals `name` when there was no collision. When
    #                 `name != original_name`, backends emit a collision
    #                 marker comment in the generated controller JS so the
    #                 reviewer can see the silent rename.
    StimulusMethod = Data.define(:name, :body_source, :original_name) do
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

    # An object-literal value (`{ key: value, ... }`) inside JSX. Lowered
    # from a JSX attribute or expression value whose root is an
    # ObjectExpression. Each property's key is a String; the value can be
    # any IR node (recursive). Backends render as a Ruby Hash literal,
    # snake_casing identifier keys to match Ruby kwarg conventions.
    #
    # properties : [[String key, Node value]] — preserved in source order.
    ObjectLiteral = Data.define(:properties) do
      include Node
    end

    # An array-literal value (`[a, b, ...]`) inside JSX. Lowered from a
    # JSX attribute or expression value whose root is an ArrayExpression.
    # Each element is an IR node (recursive). Backends render as a Ruby
    # Array literal.
    #
    # elements : [Node]
    ArrayLiteral = Data.define(:elements) do
      include Node
    end

    # An arrow/function expression appearing as an inline value (not in
    # JSX child or event-handler position). Typical example: a `render`
    # property inside an array-of-config-objects passed to an AG-Grid
    # column descriptor or antd Select option. Backends emit as a Ruby
    # method on the class (deterministically named) and reference it via
    # `method(:name)` in the value position, since lambdas don't carry
    # the Phlex execution context required to call tag.* helpers.
    #
    # params : [String]
    # body   : Node
    Lambda = Data.define(:params, :body) do
      include Node
    end

    # A render-prop child: `<Form.List>{(fields) => <div>{fields}</div>}</Form.List>`.
    # Backends emit this as a Ruby block on the render call, with the params
    # bound as block arguments. Distinct from Loop (which iterates an
    # iterable) and from Slot (which yields without args).
    #
    # params : [String] — param names (camelCase preserved; backends snake_case).
    # body   : Node — the lowered IR node produced by the arrow's body.
    RenderProp = Data.define(:params, :body) do
      include Node
    end

    # A locally-declared JSX-returning arrow that's invoked inside the
    # render body: `const renderHeader = (count) => <h1>{count}</h1>;
    # ... {renderHeader(headerCount)}`. Backends emit one private method
    # per RenderMethod on the generated class and reference it via a
    # LocalRenderCall at each use site.
    #
    # name   : String — snake_case method name on the class.
    # params : [String] — arrow param names (camelCase preserved; backends
    #          snake_case to form Ruby parameter names).
    # body   : Node — the lowered IR node produced by the arrow's body.
    RenderMethod = Data.define(:name, :params, :body) do
      include Node
    end

    # A call to a locally-declared JSX-returning arrow at its use site.
    # Pairs with a sibling RenderMethod on Component#render_methods.
    #
    # method_name : String — snake_case method name (matches RenderMethod#name).
    # args        : [Interpolation] — argument expressions captured verbatim
    #               (each Interpolation's expression is translated by the
    #               backend's ExpressionTranslator at emission time).
    LocalRenderCall = Data.define(:method_name, :args) do
      include Node
    end
  end
end
