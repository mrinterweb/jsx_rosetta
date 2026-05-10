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

      def initialize(source)
        @source = source
        @prop_names = []
        @local_jsx = {}
      end

      def lower_file(file)
        candidate = find_component_function(file.program)
        raise lowering_error("no component function found in module") unless candidate

        name, function = candidate
        lower_component(name, function)
      end

      private

      def lowering_error(message, node: nil)
        LoweringError.new(message, node: node, source: @source)
      end

      def find_component_function(program)
        program.body.each do |stmt|
          candidate =
            case stmt.type
            when "FunctionDeclaration" then [stmt[:id]&.[](:name), stmt]
            when "VariableDeclaration" then extract_arrow_component(stmt)
            when "ExportNamedDeclaration", "ExportDefaultDeclaration"
              extract_exported_component(stmt[:declaration])
            end
          return candidate if candidate
        end
        nil
      end

      def extract_exported_component(declaration)
        return nil unless declaration.is_a?(AST::Node)

        case declaration.type
        when "FunctionDeclaration" then [declaration[:id]&.[](:name), declaration]
        when "VariableDeclaration" then extract_arrow_component(declaration)
        end
      end

      def extract_arrow_component(variable_declaration)
        variable_declaration[:declarations].each do |declarator|
          init = declarator[:init]
          next unless init.is_a?(AST::Node)
          next unless %w[ArrowFunctionExpression FunctionExpression].include?(init.type)

          name = declarator[:id]&.[](:name)
          return [name, init] if name
        end
        nil
      end

      def lower_component(name, function)
        if name.nil? || name.empty?
          raise lowering_error("anonymous component functions are not supported", node: function)
        end

        props, rest_prop_name = lower_params(function[:params])
        @prop_names = props.map(&:name)

        Component.new(
          name: name,
          props: props,
          body: lower_function_body(function[:body]),
          rest_prop_name: rest_prop_name
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
          @local_jsx = collect_local_jsx_bindings(body[:body])
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

      def collect_local_jsx_bindings(statements)
        bindings = {}
        statements.each do |stmt|
          next unless stmt.type == "VariableDeclaration"

          stmt[:declarations].each do |declarator|
            init = declarator[:init]
            next unless init.is_a?(AST::Node)
            next unless %w[JSXElement JSXFragment].include?(init.type)

            name = declarator[:id]&.[](:name)
            bindings[name] = init if name
          end
        end
        bindings
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
        children = lower_children(element.jsx_children)

        if html_element?(tag)
          Element.new(tag: tag, attributes: attributes, children: children)
        else
          props = attributes.reject { |attr| attr.is_a?(Attribute) && attr.name == "key" }
          ComponentInvocation.new(name: tag, props: props, children: children)
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
        if event_attribute?(name) && attr.value.is_a?(AST::JSXExpressionContainer)
          return lower_event_attribute(name, attr.value)
        end

        Attribute.new(name: name, value: lower_attribute_value(attr.value))
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
        EventBinding.new(
          event: name.sub(/\Aon/, "").downcase,
          handler: Interpolation.new(expression: source_of(value.expression))
        )
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
