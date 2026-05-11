# frozen_string_literal: true

require_relative "types"
require_relative "module_shape_classifier"

module JsxRosetta
  module IR
    # Lowers a parsed AST::File into an IR::Component tree.
    #
    # Responsibilities:
    #   - Component discovery — find function/arrow declarations whose
    #     name and body shape qualify as a function component.
    #   - Module-shape classification — when no component is found,
    #     produce a triage-friendly error message via SHAPE_MESSAGES.
    #   - Function-body lowering — turn return-bearing block statements,
    #     if-chains, switch/try statements, and bare expression returns
    #     into IR values (Conditional, Interpolation, Text, etc.).
    #   - JSX-node lowering — turn JSXElement / JSXFragment / JSXText /
    #     JSXExpressionContainer trees into IR::Element / Fragment /
    #     ComponentInvocation / Conditional / Loop / etc.
    #   - Pattern recognition — `cn()` / `clsx()` className helpers,
    #     `items.map(...)` loops, `cond ? <A/> : <B/>` polymorphic tags,
    #     React-hook calls, and onX={...} handlers promotable to
    #     Stimulus methods.
    #
    # Anything outside these patterns is preserved verbatim as a TODO
    # so the human reviewer sees the original JS at the right spot.
    class Lowering
      # A failure during AST → IR lowering. Carries optional line/column
      # information when the failure can be tied to an AST node.
      class LoweringError < JsxRosetta::Error
        attr_reader :line, :column

        def initialize(message, node: nil, source: nil)
          @line = nil
          @column = nil

          if node && source && node.start_pos
            @line, @column = compute_line_column(source, node.start_pos)
            message = "#{message} (at line #{@line}, column #{@column})"
          end

          super(message)
        end

        private

        def compute_line_column(source, position)
          prefix = source[0...position] || ""
          line = prefix.count("\n") + 1
          last_newline = prefix.rindex("\n")
          column = last_newline ? position - last_newline - 1 : position
          [line, column + 1]
        end
      end

      def self.lower(file, source:)
        new(source).lower_file(file)
      end

      def self.lower_all(file, source:)
        new(source).lower_all_components(file)
      end

      REACT_HOOKS = %w[
        useState useEffect useRef useContext useMemo useCallback
        useReducer useImperativeHandle useLayoutEffect useDebugValue
      ].freeze

      JSX_NODE_TYPES = %w[JSXElement JSXFragment JSXText JSXExpressionContainer].freeze

      # Pre-lowering AST scan: maps a node type to a callable returning the
      # AST nodes that contribute return values. Used by body_returns_jsx?.
      JSX_RETURN_PROBES = {
        "ReturnStatement" => ->(n) { [n[:argument]] },
        "BlockStatement" => ->(n) { n[:body] },
        "IfStatement" => ->(n) { [n[:consequent], n[:alternate]] },
        "TryStatement" => ->(n) { [n[:block]] },
        "ConditionalExpression" => ->(n) { [n[:consequent], n[:alternate]] },
        "LogicalExpression" => ->(n) { [n[:left], n[:right]] }
      }.freeze

      SHAPE_MESSAGES = {
        hoc_wrapped: "looks like a HOC-wrapped component (React.memo / forwardRef / lazy / observer) — " \
                     "this version doesn't peel HOC wrappers; remove the wrapper or upgrade when supported",
        class_component: "looks like a class component — this version translates only function components " \
                         "(rewrite as a function or wait for class-component support)",
        hooks_only: "looks like a custom-hooks module — hooks encode behavior and state, not view markup; " \
                    "translate behavior to a Stimulus controller and state to server-rendered ivars",
        columns_data: "looks like a data export (top-level array literal) — not a component; " \
                      "data lives in the model or a presenter, not a ViewComponent",
        types_only: "looks like a types/constants module — no functions to translate; " \
                    "TypeScript types erase, and Ruby constants belong elsewhere",
        side_effects_only: "looks like a side-effect-only module (top-level calls, no exported functions) — " \
                           "register the equivalent setup in a Rails initializer instead",
        utils_only: "looks like a utility module — only function components and JSX-returning helpers translate; " \
                    "pure-data helpers don't have a ViewComponent equivalent",
        mixed_exports: "module mixes shapes (utilities + hooks + types + non-JSX helpers) — " \
                       "split into separate files so each module has a single shape",
        unknown: nil
      }.freeze

      def initialize(source)
        @source = source
        @prop_names = []
        @local_jsx = {}
        @local_bindings = []
        @local_binding_names = []
        @local_arrows = {}
        @local_polymorphic_tags = {}
        @local_destructures = {}
        @stimulus_methods = []
        @stimulus_seen_names = {}
        @react_hooks = []
      end

      def lower_file(file)
        candidates = find_component_functions(file.program)
        raise no_component_error(file.program) if candidates.empty?

        name, function = candidates.first
        module_bindings = capture_module_bindings(file.program, candidates)
        attach_module_bindings(lower_component(name, function), module_bindings)
      end

      def lower_all_components(file)
        candidates = find_component_functions(file.program)
        raise no_component_error(file.program) if candidates.empty?

        module_bindings = capture_module_bindings(file.program, candidates)
        candidates.map do |name, function|
          attach_module_bindings(lower_component(name, function), module_bindings)
        end
      end

      # Walk the program body for top-level `const`/`let` declarations that
      # aren't component declarations. Capture each as a LocalBinding so
      # backends can emit them as Ruby constants (or as a TODO comment for
      # non-literal initializers) before the class definition. Without
      # this, `const FOO = 400; function X() { return <p>{FOO}</p> }` would
      # silently drop the FOO declaration and emit an unbacked `foo`
      # reference inside the view template.
      def capture_module_bindings(program, candidates)
        component_names = candidates.to_set(&:first)
        bindings = []
        program.body.each do |stmt|
          walk_module_binding(stmt, component_names, bindings)
        end
        bindings
      end

      def walk_module_binding(stmt, component_names, bindings)
        case stmt.type
        when "VariableDeclaration"
          stmt[:declarations].each { |d| record_module_binding(stmt, d, component_names, bindings) }
        when "ExportNamedDeclaration"
          decl = stmt[:declaration]
          walk_module_binding(decl, component_names, bindings) if decl.is_a?(AST::Node)
        end
      end

      def record_module_binding(stmt, declarator, component_names, bindings)
        init = declarator[:init]
        return unless init.is_a?(AST::Node)

        # Component declarators (`const Foo = () => ...`) are handled by
        # the component pipeline; skip them here so the source doesn't
        # show up twice.
        return if %w[ArrowFunctionExpression FunctionExpression].include?(init.type) &&
                  component_names.include?(declarator[:id]&.[](:name))

        name = declarator[:id]&.[](:name)
        return unless name

        bindings << LocalBinding.new(name: name, source: source_of(stmt).strip)
      end

      def attach_module_bindings(component, module_bindings)
        return component if module_bindings.empty?

        component.with(module_bindings: module_bindings)
      end

      private

      def lowering_error(message, node: nil)
        LoweringError.new(message, node: node, source: @source)
      end

      def no_component_error(program)
        shape = ModuleShapeClassifier.classify(program)
        message = SHAPE_MESSAGES[shape]
        suffix = message ? " — #{message}" : ""
        lowering_error("no component function found in module#{suffix}")
      end

      def find_component_functions(program)
        program.body.flat_map { |stmt| extract_components(stmt) }
                    .compact
                    .select { |(name, fn)| component_function?(name, fn) }
      end

      # A function is a component if it's PascalCase (the React convention),
      # or if it's a lowercase-named helper whose body returns JSX. The
      # latter catches files like `CellRenderers.tsx` that export
      # `textRender`, `booleanRender`, etc. — JSX-returning by structure
      # but lowercase by convention. `use*` names are excluded — those are
      # hooks, which return data, not view markup.
      def component_function?(name, function)
        return false if name.nil? || name.empty?
        return true if pascal_case?(name)
        return false if hook_name?(name)

        body_returns_jsx?(function[:body])
      end

      def pascal_case?(name)
        first = name[0]
        first == first.upcase && first != first.downcase
      end

      def hook_name?(name)
        name.start_with?("use") && name.length > 3 && name[3] == name[3].upcase
      end

      # Pre-lowering AST scan: does any return path in this body produce a
      # JSX value? Used only as a heuristic for component_function?, so a
      # false positive is a translation attempt that may TODO out, while
      # a false negative is a missed translation. Recursion follows return
      # paths only — does not descend into nested function expressions.
      def body_returns_jsx?(node)
        return false unless node.is_a?(AST::Node)
        return true if %w[JSXElement JSXFragment].include?(node.type)
        return switch_returns_jsx?(node) if node.type == "SwitchStatement"

        probe = JSX_RETURN_PROBES[node.type]
        probe ? probe.call(node).any? { |child| body_returns_jsx?(child) } : false
      end

      def switch_returns_jsx?(node)
        node[:cases].any? { |c| c[:consequent].any? { |s| body_returns_jsx?(s) } }
      end

      def extract_components(stmt)
        case stmt.type
        when "FunctionDeclaration"
          [[stmt[:id]&.[](:name), stmt]]
        when "VariableDeclaration"
          extract_arrow_components(stmt)
        when "ExportNamedDeclaration", "ExportDefaultDeclaration"
          extract_exported_components(stmt[:declaration])
        else
          []
        end
      end

      def extract_exported_components(declaration)
        return [] unless declaration.is_a?(AST::Node)

        case declaration.type
        when "FunctionDeclaration" then [[declaration[:id]&.[](:name), declaration]]
        when "VariableDeclaration" then extract_arrow_components(declaration)
        else []
        end
      end

      def extract_arrow_components(variable_declaration)
        variable_declaration[:declarations].filter_map do |declarator|
          init = declarator[:init]
          next nil unless init.is_a?(AST::Node)
          next nil unless %w[ArrowFunctionExpression FunctionExpression].include?(init.type)

          name = declarator[:id]&.[](:name)
          name ? [name, init] : nil
        end
      end

      def lower_component(name, function)
        if name.nil? || name.empty?
          raise lowering_error("anonymous component functions are not supported", node: function)
        end

        props, rest_prop_name = lower_params(function[:params])
        @prop_names = props.map(&:name)
        @local_bindings = []
        @local_binding_names = []
        @local_arrows = {}
        @local_polymorphic_tags = {}
        @local_destructures = {}
        @stimulus_methods = []
        @stimulus_seen_names = {}
        @react_hooks = []

        body = lower_function_body(function[:body])

        Component.new(
          name: name,
          props: props,
          body: body,
          rest_prop_name: rest_prop_name,
          local_bindings: @local_bindings,
          local_binding_names: @local_binding_names.uniq,
          module_bindings: [],
          stimulus_methods: @stimulus_methods,
          react_hooks: @react_hooks
        )
      end

      def lower_params(params)
        return [[], nil] if params.nil? || params.empty?

        first_param = params.first
        case first_param.type
        when "ObjectPattern"
          lower_object_pattern_params(first_param)
        when "Identifier"
          [[Prop.new(name: first_param[:name], default: nil)], nil]
        else
          raise lowering_error("unsupported parameter shape: #{first_param.type}", node: first_param)
        end
      end

      def lower_object_pattern_params(pattern)
        props = []
        rest_name = nil
        pattern[:properties].each do |property|
          case property.type
          when "ObjectProperty"
            props << lower_object_prop(property)
          when "RestElement"
            argument = property[:argument]
            rest_name = argument.type == "Identifier" ? argument[:name] : source_of(argument)
          else
            raise lowering_error("unsupported prop pattern: #{property.type}", node: property)
          end
        end
        [props, rest_name]
      end

      def lower_object_prop(property)
        key = property[:key]
        prop_name = key.type == "StringLiteral" ? key[:value] : key[:name]
        value = property[:value]
        # Route prop default expressions through the recursive value
        # lowering so object/array literals translate cleanly, instead of
        # producing an opaque Interpolation that the backend would emit as
        # `nil # TODO: ...`. The trailing `#` comment inside a method
        # parameter list swallows the closing `)` and breaks Ruby syntax.
        default = (lower_value_expression(value[:right]) if value.type == "AssignmentPattern")
        Prop.new(name: prop_name, default: default)
      end

      def lower_function_body(body)
        if body.type == "BlockStatement"
          collect_local_bindings(body[:body])
          chained = lower_block_returns(body[:body])
          return chained if chained

          raise lowering_error("component function has no return statement", node: body)
        end

        @local_jsx = {}
        lower_return_value(body)
      end

      # Dispatch a value in return position. JSX nodes lower via lower_jsx;
      # everything else gets a sensible default — null becomes empty Text,
      # ConditionalExpression / LogicalExpression lower to Conditional,
      # Identifier inlines @local_jsx-bound JSX or emits an Interpolation,
      # literal Strings/Numbers become Text, and any other expression
      # (CallExpression, MemberExpression, BinaryExpression, TemplateLiteral,
      # …) becomes a verbatim Interpolation. This permissive default is
      # what lets lowercase JSX-returning helpers (`textRender`,
      # `moneyRender`) lower cleanly when their guard returns are non-JSX.
      def lower_return_value(node)
        case node.type
        when "ConditionalExpression" then lower_ternary_expression(node)
        when "LogicalExpression" then lower_logical_expression(node)
        when "NullLiteral" then Text.new(value: "")
        when *JSX_NODE_TYPES then lower_jsx(node)
        when "Identifier" then lower_identifier_return(node)
        when "StringLiteral" then Text.new(value: node[:value])
        when "NumericLiteral" then Text.new(value: node[:value].to_s)
        else Interpolation.new(expression: source_of(node))
        end
      end

      def lower_identifier_return(node)
        bound = @local_jsx[node[:name]]
        bound ? lower_jsx(bound) : Interpolation.new(expression: source_of(node))
      end

      # Lower a block-statement body into an IR value. Recognized shapes:
      #   - first top-level `return X;` (everything after is dead code)
      #   - trailing `if/else if/else` chain whose every branch returns
      #   - trailing `switch (subject) { case A: return X; default: return Y; }`
      #   - trailing `try { return X; } catch { ... }`
      # Any preceding `if (X) return Y;` guard statements (no else) are wrapped
      # around the base value as outer Conditionals. Returns nil when no shape
      # matches; caller raises.
      def lower_block_returns(statements)
        return_idx = statements.index { |s| AST::Node.matches?(s, "ReturnStatement") }

        if return_idx
          return_arg = statements[return_idx][:argument]
          return nil unless return_arg

          base = lower_return_value(return_arg)
          preceding = statements[0...return_idx]
        else
          last = statements.last
          return nil unless last.is_a?(AST::Node)

          base = lower_trailing_return_structure(last)
          return nil unless base

          preceding = statements[0...-1]
        end

        wrap_return_guards(preceding, base)
      end

      def lower_trailing_return_structure(stmt)
        case stmt.type
        when "IfStatement" then lower_if_return_chain(stmt)
        when "SwitchStatement" then lower_switch_return(stmt)
        when "TryStatement" then lower_try_return(stmt)
        end
      end

      # Wrap `if (X) return Y;` guard statements (no else) around `base_value`
      # as outer Conditionals. Preceding statements that we can't represent
      # (const declarations, hook calls, multi-stmt guard bodies, if-else
      # structures with multi-stmt branches) are skipped silently — they're
      # either already absorbed by collect_local_bindings (consts/hooks) or
      # they encode side effects we can't preserve. Matches the v0.2.0
      # behavior of dropping unrepresentable preceding statements rather
      # than failing the whole component.
      def wrap_return_guards(preceding, base_value)
        preceding.reverse.reduce(base_value) do |acc, stmt|
          next acc unless guard_if_statement?(stmt)

          branch_value = lower_return_branch(stmt[:consequent])
          next acc unless branch_value

          Conditional.new(
            test: Interpolation.new(expression: source_of(stmt[:test])),
            consequent: branch_value,
            alternate: acc
          )
        end
      end

      def guard_if_statement?(stmt)
        AST::Node.matches?(stmt, "IfStatement") && stmt[:alternate].nil?
      end

      def lower_if_return_chain(if_stmt)
        consequent = lower_return_branch(if_stmt[:consequent])
        return nil unless consequent

        alternate_node = if_stmt[:alternate]
        alternate = case alternate_node&.type
                    when nil then nil
                    when "IfStatement" then lower_if_return_chain(alternate_node)
                    else lower_return_branch(alternate_node)
                    end
        return nil if alternate_node && alternate.nil?

        Conditional.new(
          test: Interpolation.new(expression: source_of(if_stmt[:test])),
          consequent: consequent,
          alternate: alternate
        )
      end

      # An if-chain branch lowers to a return value via the same
      # block-handling logic that powers the outer function body:
      # variable declarations are absorbed into @local_bindings as TODOs,
      # leading `if (X) return Y;` guards wrap as Conditionals, and any
      # other preceding statements are silently dropped (since the gem
      # can't preserve their side effects). Without this consistency,
      # cases like `if (m) { const x = ...; return <X/>; } else { ... }`
      # would bail mid-body.
      def lower_return_branch(branch)
        case branch.type
        when "ReturnStatement"
          branch[:argument] && lower_return_value(branch[:argument])
        when "BlockStatement"
          collect_nested_local_bindings(branch[:body])
          lower_block_returns(branch[:body])
        end
      end

      def collect_nested_local_bindings(stmts)
        stmts.each do |stmt|
          next unless AST::Node.matches?(stmt, "VariableDeclaration")

          seen = {}
          stmt[:declarations].each { |declarator| classify_local_binding(stmt, declarator, seen) }
        end
      end

      # Lower a `switch (subject) { case A: return X; default: return Y; }`
      # to a right-nested chain of IR::Conditional. Each case must end in a
      # returnable value (bare `return X;` or a single-stmt block-return).
      # Fall-through groups (`case A: case B: return X;`) get a single
      # Conditional with an OR-joined test. The default case (or no default)
      # becomes the final alternate. Returns nil when any case has a shape
      # we don't recognize.
      def lower_switch_return(switch_stmt)
        groups = build_switch_case_groups(switch_stmt[:cases])
        return nil unless groups

        subject_src = source_of(switch_stmt[:discriminant])
        default_value, non_default = split_switch_default(groups)

        non_default.reverse.reduce(default_value) do |alternate, group|
          test_expr = group[:tests].map { |t| "#{subject_src} === #{source_of(t)}" }.join(" || ")
          Conditional.new(
            test: Interpolation.new(expression: test_expr),
            consequent: group[:value],
            alternate: alternate
          )
        end
      end

      def build_switch_case_groups(cases)
        groups = []
        pending_tests = []
        pending_default = false

        cases.each do |case_node|
          if case_node[:test].nil?
            pending_default = true
          else
            pending_tests << case_node[:test]
          end

          consequent_stmts = case_node[:consequent]
          next if consequent_stmts.empty?

          value = lower_switch_case_consequent(consequent_stmts)
          return nil unless value

          groups << {
            tests: pending_default ? [] : pending_tests.dup,
            is_default: pending_default,
            value: value
          }
          pending_tests.clear
          pending_default = false
        end

        return nil if pending_default || pending_tests.any?

        groups
      end

      def split_switch_default(groups)
        default_group = groups.find { |g| g[:is_default] }
        default_value = default_group ? default_group[:value] : Text.new(value: "")
        non_default = groups.reject { |g| g[:is_default] }
        [default_value, non_default]
      end

      # A switch case body lowers when it returns from every reachable path.
      # Recognized shapes:
      #   case A: return X;                   (bare return)
      #   case A: { return X; }               (block-wrapped return)
      #   case A: { const y = ...; return X; } (leading vars + return)
      #   case A: if (X) return Y; return Z;  (guard prefix + return)
      # Trailing `break` statements are ignored.
      def lower_switch_case_consequent(stmts)
        filtered = stmts.reject { |s| AST::Node.matches?(s, "BreakStatement") }
        return nil if filtered.empty?

        if filtered.size == 1 && AST::Node.matches?(filtered.first, "BlockStatement")
          return lower_switch_case_consequent(filtered.first[:body])
        end

        collect_nested_local_bindings(filtered)
        lower_block_returns(filtered)
      end

      # Lower `try { ...; return X; } catch (e) { ... } [finally { ... }]` by
      # treating the try block's body as the function body. Catch/finally
      # handlers are dropped — they typically encode JS-only error semantics
      # that won't translate. Returns nil when the try block has no
      # recognizable return shape.
      def lower_try_return(try_stmt)
        block_body = try_stmt[:block][:body]
        lower_block_returns(block_body)
      end

      def collect_local_bindings(statements)
        @local_jsx = {}
        @local_arrows = {}
        @local_polymorphic_tags = {}
        @local_destructures = {}
        seen_other_stmts = {}

        statements.each do |stmt|
          case stmt.type
          when "VariableDeclaration"
            stmt[:declarations].each { |declarator| classify_local_binding(stmt, declarator, seen_other_stmts) }
          when "ExpressionStatement"
            detect_bare_hook_call(stmt)
          end
        end
      end

      def classify_local_binding(stmt, declarator, seen)
        init = declarator[:init]
        return unless init.is_a?(AST::Node)

        is_hook = hook_call?(init)
        @react_hooks << ReactHookCall.new(hook: init[:callee][:name], source: source_of(stmt).strip) if is_hook

        id_node = declarator[:id]
        if destructure_pattern?(id_node)
          # Capture destructured names so the ExpressionTranslator recognizes
          # them as known-local bindings and emits a `nil` placeholder
          # instead of a bare unresolved reference (which NameErrors at
          # render time). Hook destructures (`const [open, setOpen] = useState(0)`)
          # contribute names but not a separate LocalBinding TODO — the
          # hook's source already shows the binding to the reviewer.
          # Also track member-expression destructures (Gap J) so
          # `const { Content } = Layout` lets `<Content/>` resolve to
          # `Layout::Content`.
          record_destructured_names(stmt, declarator, init: init, seen: seen, is_hook: is_hook)
          return
        end

        return if is_hook

        name = id_node&.[](:name)
        return unless name

        case init.type
        when "JSXElement", "JSXFragment"
          @local_jsx[name] = init
        when "ArrowFunctionExpression", "FunctionExpression"
          @local_arrows[name] = init
        when "ConditionalExpression"
          poly = lower_polymorphic_tag(init)
          poly ? (@local_polymorphic_tags[name] = poly) : record_local_other_binding(stmt, name, seen)
        else
          record_local_other_binding(stmt, name, seen)
        end
      end

      def destructure_pattern?(node)
        AST::Node.matches?(node, "ArrayPattern", "ObjectPattern")
      end

      def record_destructured_names(stmt, declarator, init:, seen:, is_hook:)
        pattern = declarator[:id]
        names = destructured_names_of(pattern)
        return if names.empty?

        # Member-expression-style destructuring (Gap J): `const { Content } = Layout`
        # binds `Content` to `Layout.Content`. Record those so JSX use sites
        # resolve to the right component.
        track_member_destructures(pattern, init) if AST::Node.matches?(init, "Identifier")

        @local_binding_names.concat(names)
        return if is_hook

        seen[stmt.start_pos] ||= source_of(stmt).strip
        names.each { |name| @local_bindings << LocalBinding.new(name: name, source: seen[stmt.start_pos]) }
      end

      # Return the flat list of Identifier names bound by a destructuring
      # pattern. Nested patterns recurse. RestElement / aliased properties
      # are included; defaults (AssignmentPattern) are followed to their
      # left-hand identifier.
      def destructured_names_of(pattern)
        return [] unless pattern.is_a?(AST::Node)

        case pattern.type
        when "Identifier" then [pattern[:name]]
        when "ArrayPattern"
          pattern[:elements].flat_map { |element| element ? destructured_names_of(element) : [] }
        when "ObjectPattern"
          pattern[:properties].flat_map { |prop| destructured_names_from_property(prop) }
        when "RestElement"
          destructured_names_of(pattern[:argument])
        when "AssignmentPattern"
          destructured_names_of(pattern[:left])
        else
          []
        end
      end

      def destructured_names_from_property(prop)
        case prop.type
        when "ObjectProperty" then destructured_names_of(prop[:value])
        when "RestElement" then destructured_names_of(prop[:argument])
        else []
        end
      end

      def track_member_destructures(pattern, source_identifier)
        return unless AST::Node.matches?(pattern, "ObjectPattern")

        source_name = source_identifier[:name]
        pattern[:properties].each do |prop|
          next unless prop.type == "ObjectProperty"

          value = prop[:value]
          next unless AST::Node.matches?(value, "Identifier")

          @local_destructures[value[:name]] = source_name
        end
      end

      def detect_bare_hook_call(stmt)
        expr = stmt.child(:expression)
        return unless expr&.of_type?("CallExpression") && hook_call?(expr)

        @react_hooks << ReactHookCall.new(hook: expr[:callee][:name], source: source_of(stmt).strip)
      end

      def hook_call?(call_expression)
        return false unless call_expression.of_type?("CallExpression")

        callee = call_expression.child(:callee)
        callee&.of_type?("Identifier") && REACT_HOOKS.include?(callee[:name])
      end

      # Recognize the asChild-style polymorphic tag pattern:
      #   const Comp = condition ? <BranchA> : <BranchB>;
      # where each branch is a JSX-renderable thing — a string-literal HTML
      # tag name (`"button"`), an Identifier (`Slot`), or a MemberExpression
      # (`Slot.Root`). Returns nil when the shape isn't recognized so the
      # caller can fall back to the verbatim TODO-comment behavior.
      def lower_polymorphic_tag(conditional)
        true_branch = polymorphic_tag_branch(conditional[:consequent])
        false_branch = polymorphic_tag_branch(conditional[:alternate])
        return nil unless true_branch && false_branch

        { test: conditional[:test], true_branch: true_branch, false_branch: false_branch }
      end

      def polymorphic_tag_branch(node)
        case node.type
        when "StringLiteral" then { kind: :element, tag: node[:value] }
        when "Identifier" then { kind: :component, tag: node[:name] }
        when "MemberExpression" then { kind: :component, tag: source_of(node) }
        end
      end

      def record_local_other_binding(stmt, name, seen)
        seen[stmt.start_pos] ||= source_of(stmt).strip
        @local_bindings << LocalBinding.new(name: name, source: seen[stmt.start_pos])
        @local_binding_names << name
      end

      def lower_jsx(node)
        case node
        when AST::JSXElement then lower_jsx_element(node)
        when AST::JSXFragment then lower_jsx_fragment(node)
        when AST::JSXText then lower_jsx_text(node)
        when AST::JSXExpressionContainer then lower_jsx_expression(node)
        else
          raise lowering_error("unexpected JSX node in lowering: #{node.type}", node: node)
        end
      end

      def lower_jsx_element(element)
        tag = element.tag_name
        attributes = element.opening_element.attributes.filter_map { |attr| lower_attribute(attr, tag: tag) }
        # `key` is a React-only reconciliation hint; never emit it to the DOM
        # or to ViewComponent invocations.
        attributes = attributes.reject { |attr| attr.is_a?(Attribute) && attr.name == "key" }
        children = lower_children(element.jsx_children)

        if (poly = @local_polymorphic_tags[tag])
          lower_polymorphic_tag_use(poly, attributes, children)
        elsif (parent = @local_destructures[tag])
          # Gap J: `const { Content } = Layout; <Content/>` should resolve
          # to `Layout::Content`, not a bare `ContentComponent`.
          ComponentInvocation.new(name: "#{parent}.#{tag}", props: attributes, children: children)
        elsif html_element?(tag)
          Element.new(tag: tag, attributes: attributes, children: children)
        else
          ComponentInvocation.new(name: tag, props: attributes, children: children)
        end
      end

      def lower_polymorphic_tag_use(poly, attributes, children)
        Conditional.new(
          test: Interpolation.new(expression: source_of(poly[:test])),
          consequent: build_polymorphic_branch(poly[:true_branch], attributes, children),
          alternate: build_polymorphic_branch(poly[:false_branch], attributes, children)
        )
      end

      def build_polymorphic_branch(branch, attributes, children)
        case branch[:kind]
        when :element
          Element.new(tag: branch[:tag], attributes: attributes, children: children)
        when :component
          ComponentInvocation.new(name: branch[:tag], props: attributes, children: children)
        end
      end

      def lower_jsx_fragment(fragment)
        Fragment.new(children: lower_children(fragment.jsx_children))
      end

      def lower_children(children)
        children.filter_map do |child|
          case child
          when AST::JSXText
            lower_jsx_text(child)
          else
            lower_jsx(child)
          end
        end
      end

      def lower_jsx_text(node)
        value = normalize_jsx_text(node.value)
        return nil if value.empty?

        Text.new(value: value)
      end

      # Apply JSX whitespace rules (matching Babel's cleanJSXElementLiteralChild):
      #   - tabs are converted to spaces
      #   - leading whitespace on every line except the first is stripped
      #   - trailing whitespace on every line except the last is stripped
      #   - non-empty lines are joined; each non-final non-empty line gets a
      #     trailing space appended
      #   - all-whitespace text becomes empty (caller drops it)
      def normalize_jsx_text(value)
        lines = value.split(/\r\n|\n|\r/)
        last_non_empty = nil
        lines.each_with_index { |line, i| last_non_empty = i if line.match?(/[^ \t]/) }
        return "" if last_non_empty.nil?

        result = String.new
        lines.each_with_index do |line, i|
          trimmed = line.tr("\t", " ")
          trimmed = trimmed.sub(/\A +/, "") unless i.zero?
          trimmed = trimmed.sub(/ +\z/, "") unless i == lines.length - 1
          next if trimmed.empty?

          trimmed += " " unless i == last_non_empty
          result << trimmed
        end
        result
      end

      def lower_jsx_expression(node)
        expression = node.expression
        return lower_jsx_comment(expression) if expression.is_a?(AST::JSXEmptyExpression)

        case expression.type
        when "StringLiteral" then Text.new(value: expression[:value])
        when "NumericLiteral" then Text.new(value: expression[:value].to_s)
        when "BooleanLiteral", "NullLiteral" then nil
        when "LogicalExpression" then lower_logical_expression(expression)
        when "ConditionalExpression" then lower_ternary_expression(expression)
        when "Identifier" then lower_identifier_expression(expression)
        when "CallExpression" then lower_call_expression(expression)
        when "ArrowFunctionExpression", "FunctionExpression" then lower_render_prop(expression)
        else
          Interpolation.new(expression: source_of(expression))
        end
      end

      # Recognize the render-prop / function-as-children pattern:
      #   <Form.List>{(fields, helpers) => <div>{fields}</div>}</Form.List>
      # Returns nil (caller falls back to verbatim interpolation) when the
      # arrow has zero or too many params, or when the body doesn't lower
      # cleanly to a JSX child.
      def lower_render_prop(arrow)
        params = arrow[:params]
        return Interpolation.new(expression: source_of(arrow)) if params.size > 4
        unless params.all? { |p| AST::Node.matches?(p, "Identifier") }
          return Interpolation.new(expression: source_of(arrow))
        end

        body = lower_arrow_body(arrow[:body])
        return Interpolation.new(expression: source_of(arrow)) unless body

        RenderProp.new(params: params.map { |p| p[:name] }, body: body)
      end

      def lower_jsx_comment(empty_expression)
        comments = empty_expression.raw["innerComments"]
        return nil if comments.nil? || comments.empty?

        Comment.new(text: comments.map { |c| c["value"] }.join("\n").strip)
      end

      def lower_call_expression(expression)
        loop_node = try_lower_map_loop(expression)
        loop_node || Interpolation.new(expression: source_of(expression))
      end

      def try_lower_map_loop(call_expression)
        callee = call_expression.child(:callee)
        return nil unless callee&.of_type?("MemberExpression")

        property = callee.child(:property)
        return nil unless property && property[:name] == "map"

        arrow = map_loop_arrow(call_expression[:arguments])
        return nil unless arrow

        params = arrow[:params]
        body = lower_arrow_body(arrow[:body])
        return nil unless body

        Loop.new(
          iterable: lower_loop_iterable(callee[:object]),
          item_binding: params[0][:name],
          index_binding: params[1] && params[1][:name],
          body: body
        )
      end

      # Recognize ArrayExpression/ObjectExpression iterables so a literal-
      # rooted `.map(...)` doesn't bail at translation time. Falls back to
      # the verbatim Interpolation for everything else.
      def lower_loop_iterable(object)
        case object.type
        when "ArrayExpression" then lower_array_literal(object)
        else Interpolation.new(expression: source_of(object))
        end
      end

      def map_loop_arrow(args)
        return nil if args.size != 1

        arrow = args.first
        return nil unless AST::Node.matches?(arrow, "ArrowFunctionExpression")

        params = arrow[:params]
        return nil if params.empty? || params.size > 2
        return nil unless params.all? { |p| AST::Node.matches?(p, "Identifier") }

        arrow
      end

      def lower_arrow_body(body)
        case body.type
        when "JSXElement", "JSXFragment"
          lower_jsx(body)
        when "BlockStatement"
          return_stmt = body[:body].find { |s| s.type == "ReturnStatement" }
          return nil unless return_stmt

          arg = return_stmt[:argument]
          return nil unless %w[JSXElement JSXFragment].include?(arg&.type)

          lower_jsx(arg)
        end
      end

      def lower_logical_expression(expr)
        if expr[:operator] == "&&"
          Conditional.new(
            test: Interpolation.new(expression: source_of(expr[:left])),
            consequent: lower_jsx_or_value(expr[:right]),
            alternate: nil
          )
        else
          Interpolation.new(expression: source_of(expr))
        end
      end

      def lower_ternary_expression(expr)
        alternate_node = expr[:alternate]
        alternate = alternate_node.type == "NullLiteral" ? nil : lower_jsx_or_value(alternate_node)

        Conditional.new(
          test: Interpolation.new(expression: source_of(expr[:test])),
          consequent: lower_jsx_or_value(expr[:consequent]),
          alternate: alternate
        )
      end

      def lower_identifier_expression(identifier)
        name = identifier[:name]
        if name == "children" && @prop_names.include?("children")
          Slot.new(name: "children")
        elsif (jsx = @local_jsx[name])
          lower_jsx(jsx)
        else
          Interpolation.new(expression: name)
        end
      end

      def lower_jsx_or_value(node)
        case node.type
        when "JSXElement", "JSXFragment"
          lower_jsx(node)
        when "Identifier"
          jsx = @local_jsx[node[:name]]
          jsx ? lower_jsx(jsx) : Interpolation.new(expression: source_of(node))
        else
          Interpolation.new(expression: source_of(node))
        end
      end

      def lower_attribute(attr, tag:)
        case attr
        when AST::JSXAttribute
          lower_jsx_attribute(attr, tag: tag)
        when AST::JSXSpreadAttribute
          SpreadAttribute.new(expression: source_of(attr.argument))
        end
      end

      # When the JSX tag is a component (PascalCase or member-expression),
      # `on*` props are NOT DOM events — they're callback props the receiving
      # Ruby component decides how to handle. Stimulus action descriptors
      # only fire on real DOM events, so promoting them would generate
      # never-firing `data-action="change->foo#h"` markup. Pass through as
      # a regular component-prop kwarg instead.
      def lower_jsx_attribute(attr, tag:)
        name = attr.attribute_name

        return lower_class_name(attr.value) if name == "className"
        return lower_style_attribute_or_fallback(attr.value) if name == "style"
        if event_attribute?(name) && attr.value.is_a?(AST::JSXExpressionContainer) && html_element?(tag)
          return lower_event_attribute(name, attr.value)
        end

        Attribute.new(name: name, value: lower_attribute_value(attr.value))
      end

      def lower_style_attribute_or_fallback(value)
        lower_style_attribute(value) || Attribute.new(name: "style", value: lower_attribute_value(value))
      end

      def lower_style_attribute(value)
        return nil unless value.is_a?(AST::JSXExpressionContainer)

        expression = value.expression
        return nil unless AST::Node.matches?(expression, "ObjectExpression")

        declarations = expression[:properties].map { |prop| lower_style_property(prop) }
        return nil if declarations.any?(&:nil?)

        Style.new(declarations: declarations)
      end

      def lower_style_property(property)
        return nil unless property.type == "ObjectProperty"

        property_name =
          case property[:key].type
          when "Identifier" then css_property_from_camel(property[:key][:name])
          when "StringLiteral" then property[:key][:value]
          end
        return nil if property_name.nil?

        value = lower_style_value(property[:value])
        return nil if value.nil?

        StyleDeclaration.new(property: property_name, value: value)
      end

      def lower_style_value(value)
        case value.type
        when "StringLiteral" then value[:value]
        when "NumericLiteral" then value[:value].to_s
        when "Identifier", "MemberExpression"
          Interpolation.new(expression: source_of(value))
        end
      end

      def css_property_from_camel(name)
        name.gsub(/([a-z\d])([A-Z])/, '\1-\2').downcase
      end

      def lower_class_name(value)
        if value.is_a?(AST::JSXExpressionContainer)
          decomposed = try_lower_class_helper(value.expression)
          return decomposed if decomposed
        end
        StyleBinding.new(expression: style_binding_expression(value))
      end

      def try_lower_class_helper(expression)
        return nil unless AST::Node.matches?(expression, "CallExpression")

        callee = expression.child(:callee)
        return nil unless callee&.of_type?("Identifier")
        return nil unless %w[cn clsx classnames].include?(callee[:name])

        segments = expression[:arguments].flat_map { |arg| lower_class_helper_arg(arg) }
        return nil if segments.any?(&:nil?)

        ClassList.new(segments: segments)
      end

      def lower_class_helper_arg(arg)
        case arg.type
        when "StringLiteral" then arg[:value]
        when "Identifier", "MemberExpression" then Interpolation.new(expression: source_of(arg))
        when "ObjectExpression" then lower_class_helper_object(arg)
        end
      end

      def lower_class_helper_object(object_expression)
        object_expression[:properties].map do |prop|
          break [nil] unless prop.type == "ObjectProperty"

          class_name =
            case prop[:key].type
            when "StringLiteral" then prop[:key][:value]
            when "Identifier" then prop[:key][:name]
            end
          break [nil] if class_name.nil?

          ConditionalSegment.new(
            class_name: class_name,
            condition: Interpolation.new(expression: source_of(prop[:value]))
          )
        end
      end

      def event_attribute?(name)
        name.match?(/\Aon[A-Z]\w*\z/)
      end

      def lower_event_attribute(name, value)
        event = name.sub(/\Aon/, "").downcase
        expression = value.expression

        stimulus = try_promote_to_stimulus(name, event, expression)
        return stimulus if stimulus

        EventBinding.new(
          event: event,
          handler: Interpolation.new(expression: source_of(expression))
        )
      end

      # Promote a JSX event-handler attribute (`onClick={...}`, `onChange={...}`)
      # to a Stimulus method binding. Three input shapes are recognized:
      #   - inline arrow / function expression (`onClick={() => doX()}`)
      #     → method body is the arrow's body source.
      #   - identifier referring to a local arrow binding
      #     (`const h = () => doX(); onClick={h}`) → method body is the
      #     bound arrow's body. The local arrow is consumed.
      #   - identifier referring to a prop or external (`onClick={onChange}`)
      #     → synthesizes a method whose body documents the original
      #     reference. Without this branch, prop-handler bindings used to
      #     fall through to an EventBinding that rendered as a broken
      #     `data-action` (a Ruby reference, not a Stimulus action descriptor).
      def try_promote_to_stimulus(attr_name, event, expression)
        case expression.type
        when "ArrowFunctionExpression", "FunctionExpression"
          promote_arrow_to_stimulus(attr_name, event, expression, name_hint: nil)
        when "Identifier"
          promote_identifier_event(attr_name, event, expression[:name])
        end
      end

      def promote_arrow_to_stimulus(attr_name, event, arrow_node, name_hint:)
        base = name_hint || default_stimulus_method_name(attr_name)
        method_name = stimulus_method_name(base)
        body_source = source_of(arrow_node[:body])
        @stimulus_methods << StimulusMethod.new(
          name: method_name, body_source: body_source, original_name: base
        )
        @local_arrows.delete(name_hint) if name_hint
        StimulusBinding.new(event: event, method_name: method_name)
      end

      def promote_identifier_event(attr_name, event, identifier_name)
        if (arrow = @local_arrows[identifier_name])
          return promote_arrow_to_stimulus(attr_name, event, arrow, name_hint: identifier_name)
        end

        method_name = stimulus_method_name(identifier_name)
        body_source = "// originally bound to: #{identifier_name}"
        @stimulus_methods << StimulusMethod.new(
          name: method_name, body_source: body_source, original_name: identifier_name
        )
        StimulusBinding.new(event: event, method_name: method_name)
      end

      def default_stimulus_method_name(attr_name)
        # `onClick` → `clickHandler`
        event = attr_name.sub(/\Aon/, "")
        "#{event[0].downcase}#{event[1..]}Handler"
      end

      def stimulus_method_name(base)
        @stimulus_seen_names[base] ||= 0
        @stimulus_seen_names[base] += 1
        @stimulus_seen_names[base] == 1 ? base : "#{base}#{@stimulus_seen_names[base]}"
      end

      def lower_attribute_value(value)
        case value
        when nil
          true
        when AST::JSXExpressionContainer
          lower_value_expression(value.expression)
        else
          value.raw["value"]
        end
      end

      # Recursively lower an arbitrary JS expression into structured IR
      # when possible: ObjectExpression → ObjectLiteral, ArrayExpression
      # → ArrayLiteral, ArrowFunctionExpression / FunctionExpression →
      # Lambda. Everything else falls back to the verbatim Interpolation
      # so simpler ExpressionTranslator paths still get a crack at it.
      def lower_value_expression(expression)
        case expression.type
        when "ObjectExpression" then lower_object_literal(expression)
        when "ArrayExpression" then lower_array_literal(expression)
        when "ArrowFunctionExpression", "FunctionExpression" then lower_value_lambda(expression)
        else
          Interpolation.new(expression: source_of(expression))
        end
      end

      def lower_object_literal(object_expression)
        properties = []
        object_expression[:properties].each do |prop|
          # Spreads inside object literals, computed keys, getters/setters,
          # methods — fall back to a verbatim Interpolation since we can't
          # represent them as a simple key-value pair.
          return Interpolation.new(expression: source_of(object_expression)) unless prop.type == "ObjectProperty"
          return Interpolation.new(expression: source_of(object_expression)) if prop.raw["computed"]

          key_name = object_property_key_name(prop[:key])
          return Interpolation.new(expression: source_of(object_expression)) if key_name.nil?

          properties << [key_name, lower_value_expression(prop[:value])]
        end
        ObjectLiteral.new(properties: properties)
      end

      def object_property_key_name(key_node)
        case key_node.type
        when "Identifier" then key_node[:name]
        when "StringLiteral" then key_node[:value]
        when "NumericLiteral" then key_node[:value].to_s
        end
      end

      def lower_array_literal(array_expression)
        elements = array_expression[:elements].map do |el|
          next nil if el.nil? # `[1, , 3]` holes — Ruby has no equivalent

          lower_value_expression(el)
        end
        ArrayLiteral.new(elements: elements)
      end

      def lower_value_lambda(arrow)
        params = arrow[:params]
        return Interpolation.new(expression: source_of(arrow)) if params.size > 4
        unless params.all? { |p| AST::Node.matches?(p, "Identifier") }
          return Interpolation.new(expression: source_of(arrow))
        end

        body = lower_lambda_body(arrow[:body])
        return Interpolation.new(expression: source_of(arrow)) unless body

        Lambda.new(params: params.map { |p| p[:name] }, body: body)
      end

      def lower_lambda_body(body)
        return lower_jsx(body) if %w[JSXElement JSXFragment].include?(body.type)

        return unless body.type == "BlockStatement"

        return_stmt = body[:body].find { |s| s.type == "ReturnStatement" }
        return nil unless return_stmt && return_stmt[:argument]

        arg = return_stmt[:argument]
        %w[JSXElement JSXFragment].include?(arg.type) ? lower_jsx(arg) : nil
      end

      def style_binding_expression(value)
        case value
        when nil then "true"
        when AST::JSXExpressionContainer then source_of(value.expression)
        else source_of(value)
        end
      end

      def html_element?(tag)
        return false if tag.nil? || tag.empty?
        return false if tag.include?(".")

        first = tag[0]
        first == first.downcase
      end

      def source_of(node)
        @source[node.start_pos...node.end_pos]
      end
    end
  end
end
