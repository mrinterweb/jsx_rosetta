# frozen_string_literal: true

require_relative "types"

module JsxRosetta
  module IR
    # Lowers a parsed AST::File into an IR::Component tree.
    #
    # Phase 2 scope:
    #   - Single function-declaration component per file.
    #   - JSX elements with lowercase tags lower to IR::Element; others to
    #     IR::ComponentInvocation.
    #   - className attributes lower to IR::StyleBinding; everything else
    #     to IR::Attribute (event handlers like onClick are passed through
    #     as Attribute for now and will be re-lowered to EventBinding in
    #     a later phase).
    #   - JS expressions are preserved as opaque source text via
    #     IR::Interpolation. No JS-to-Ruby translation.
    #   - Pure-whitespace JSXText between elements is dropped (matches
    #     JSX runtime behavior); other text is preserved verbatim.
    #
    # Phase 4a additions:
    #   - {children} where `children` is a prop lowers to IR::Slot.
    #   - {cond && X}, {cond ? X : null}, and {cond ? X : Y} lower to
    #     IR::Conditional. Other LogicalExpression operators (||, ??) are
    #     left as opaque interpolations.
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

      def initialize(source)
        @source = source
        @prop_names = []
        @local_jsx = {}
        @local_bindings = []
        @local_arrows = {}
        @local_polymorphic_tags = {}
        @stimulus_methods = []
        @stimulus_seen_names = {}
        @react_hooks = []
      end

      def lower_file(file)
        candidates = find_component_functions(file.program)
        raise lowering_error("no component function found in module") if candidates.empty?

        name, function = candidates.first
        lower_component(name, function)
      end

      def lower_all_components(file)
        candidates = find_component_functions(file.program)
        raise lowering_error("no component function found in module") if candidates.empty?

        candidates.map { |name, function| lower_component(name, function) }
      end

      private

      def lowering_error(message, node: nil)
        LoweringError.new(message, node: node, source: @source)
      end

      def find_component_functions(program)
        program.body.flat_map { |stmt| extract_components(stmt) }
                    .compact
                    .select { |(name, _)| component_name?(name) }
      end

      # React convention: components are PascalCase, hooks are camelCase
      # starting with `use`, plain helpers are lowercase. Only PascalCase
      # names are treated as components.
      def component_name?(name)
        return false if name.nil? || name.empty?

        first = name[0]
        first == first.upcase && first != first.downcase
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
        @local_arrows = {}
        @local_polymorphic_tags = {}
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
        value = property[:value]
        if value.type == "AssignmentPattern"
          Prop.new(
            name: value[:left][:name],
            default: Interpolation.new(expression: source_of(value[:right]))
          )
        else
          Prop.new(name: value[:name], default: nil)
        end
      end

      def lower_function_body(body)
        case body.type
        when "BlockStatement"
          collect_local_bindings(body[:body])
          return_stmt = body[:body].find { |stmt| stmt.type == "ReturnStatement" }
          raise lowering_error("component function has no return statement", node: body) unless return_stmt

          lower_jsx(return_stmt[:argument])
        when "JSXElement", "JSXFragment"
          @local_jsx = {}
          lower_jsx(body)
        else
          raise lowering_error("unsupported component body: #{body.type}", node: body)
        end
      end

      def collect_local_bindings(statements)
        @local_jsx = {}
        @local_arrows = {}
        @local_polymorphic_tags = {}
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

        if hook_call?(init)
          @react_hooks << ReactHookCall.new(hook: init[:callee][:name], source: source_of(stmt).strip)
          return
        end

        name = declarator[:id]&.[](:name)
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

      def detect_bare_hook_call(stmt)
        expr = stmt[:expression]
        return unless expr.is_a?(AST::Node) && expr.type == "CallExpression"
        return unless hook_call?(expr)

        @react_hooks << ReactHookCall.new(hook: expr[:callee][:name], source: source_of(stmt).strip)
      end

      def hook_call?(call_expression)
        return false unless call_expression.type == "CallExpression"

        callee = call_expression[:callee]
        callee.is_a?(AST::Node) && callee.type == "Identifier" && REACT_HOOKS.include?(callee[:name])
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
        attributes = element.opening_element.attributes.filter_map { |attr| lower_attribute(attr) }
        # `key` is a React-only reconciliation hint; never emit it to the DOM
        # or to ViewComponent invocations.
        attributes = attributes.reject { |attr| attr.is_a?(Attribute) && attr.name == "key" }
        children = lower_children(element.jsx_children)

        if (poly = @local_polymorphic_tags[tag])
          lower_polymorphic_tag_use(poly, attributes, children)
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
        else
          Interpolation.new(expression: source_of(expression))
        end
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

      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      def try_lower_map_loop(call_expression)
        callee = call_expression[:callee]
        return nil unless callee.is_a?(AST::Node) && callee.type == "MemberExpression"
        return nil unless callee[:property].is_a?(AST::Node) && callee[:property][:name] == "map"

        args = call_expression[:arguments]
        return nil if args.size != 1
        return nil unless args.first.type == "ArrowFunctionExpression"

        arrow = args.first
        params = arrow[:params]
        return nil if params.empty? || params.size > 2
        return nil unless params.all? { |p| p.is_a?(AST::Node) && p.type == "Identifier" }

        body = lower_arrow_body(arrow[:body])
        return nil unless body

        Loop.new(
          iterable: Interpolation.new(expression: source_of(callee[:object])),
          item_binding: params[0][:name],
          index_binding: params[1] && params[1][:name],
          body: body
        )
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

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

      def lower_attribute(attr)
        case attr
        when AST::JSXAttribute
          lower_jsx_attribute(attr)
        when AST::JSXSpreadAttribute
          SpreadAttribute.new(expression: source_of(attr.argument))
        end
      end

      def lower_jsx_attribute(attr)
        name = attr.attribute_name

        return lower_class_name(attr.value) if name == "className"
        return lower_style_attribute_or_fallback(attr.value) if name == "style"
        if event_attribute?(name) && attr.value.is_a?(AST::JSXExpressionContainer)
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
        return nil unless expression.is_a?(AST::Node) && expression.type == "ObjectExpression"

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
        return nil unless expression.is_a?(AST::Node) && expression.type == "CallExpression"

        callee = expression[:callee]
        return nil unless callee.is_a?(AST::Node) && callee.type == "Identifier"
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

      def try_promote_to_stimulus(attr_name, event, expression)
        arrow_node, name_hint = stimulus_arrow_for(expression)
        return nil unless arrow_node

        method_name = stimulus_method_name(name_hint || default_stimulus_method_name(attr_name))
        body_source = source_of(arrow_node[:body])
        @stimulus_methods << StimulusMethod.new(name: method_name, body_source: body_source)
        @local_arrows.delete(name_hint) if name_hint

        StimulusBinding.new(event: event, method_name: method_name)
      end

      def stimulus_arrow_for(expression)
        case expression.type
        when "ArrowFunctionExpression", "FunctionExpression"
          [expression, nil]
        when "Identifier"
          arrow = @local_arrows[expression[:name]]
          arrow ? [arrow, expression[:name]] : nil
        end
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
          Interpolation.new(expression: source_of(value.expression))
        else
          value.raw["value"]
        end
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
