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
    #     Phase 4).
    #   - JS expressions are preserved as opaque source text via
    #     IR::Interpolation. No JS-to-Ruby translation.
    #   - Pure-whitespace JSXText between elements is dropped (matches
    #     JSX runtime behavior); other text is preserved verbatim.
    class Lowering
      class LoweringError < JsxRosetta::Error; end

      def self.lower(file, source:)
        new(source).lower_file(file)
      end

      def initialize(source)
        @source = source
      end

      def lower_file(file)
        function = find_component_function(file.program)
        raise LoweringError, "no component function found in module" unless function

        lower_component(function)
      end

      private

      def find_component_function(program)
        program.body.each do |stmt|
          case stmt.type
          when "FunctionDeclaration"
            return stmt
          when "ExportNamedDeclaration", "ExportDefaultDeclaration"
            decl = stmt[:declaration]
            return decl if decl.is_a?(AST::Node) && decl.type == "FunctionDeclaration"
          end
        end
        nil
      end

      def lower_component(function)
        Component.new(
          name: function[:id]&.[](:name) || raise(LoweringError, "anonymous component functions are not supported"),
          props: lower_props(function[:params]),
          body: lower_component_body(function[:body])
        )
      end

      def lower_props(params)
        return [] if params.nil? || params.empty?

        first_param = params.first
        case first_param.type
        when "ObjectPattern"
          first_param[:properties].map { |property| lower_prop(property) }
        when "Identifier"
          # `function Button(props) { ... }` — props bag, opaque.
          [Prop.new(name: first_param[:name], default: nil)]
        else
          raise LoweringError, "unsupported parameter shape: #{first_param.type}"
        end
      end

      def lower_prop(property)
        case property.type
        when "ObjectProperty"
          lower_object_prop(property)
        when "RestElement"
          # `function X({ a, ...rest })` — pass through as a single prop name
          Prop.new(name: source_of(property[:argument]), default: nil)
        else
          raise LoweringError, "unsupported prop pattern: #{property.type}"
        end
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

      def lower_component_body(block_statement)
        return_stmt = block_statement[:body].find { |stmt| stmt.type == "ReturnStatement" }
        raise LoweringError, "component function has no return statement" unless return_stmt

        lower_jsx(return_stmt[:argument])
      end

      def lower_jsx(node)
        case node
        when AST::JSXElement then lower_jsx_element(node)
        when AST::JSXFragment then lower_jsx_fragment(node)
        when AST::JSXText then lower_jsx_text(node)
        when AST::JSXExpressionContainer then lower_jsx_expression(node)
        else
          raise LoweringError, "unexpected JSX node in lowering: #{node.type}"
        end
      end

      def lower_jsx_element(element)
        tag = element.tag_name
        attributes = element.opening_element.attributes.filter_map { |attr| lower_attribute(attr) }
        children = lower_children(element.jsx_children)

        if html_element?(tag)
          Element.new(tag: tag, attributes: attributes, children: children)
        else
          ComponentInvocation.new(name: tag, props: attributes, children: children)
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
        value = node.value
        return nil if value.strip.empty?

        Text.new(value: value)
      end

      def lower_jsx_expression(node)
        expression = node.expression
        return nil if expression.is_a?(AST::JSXEmptyExpression)

        Interpolation.new(expression: source_of(expression))
      end

      def lower_attribute(attr)
        case attr
        when AST::JSXAttribute
          lower_jsx_attribute(attr)
        when AST::JSXSpreadAttribute
          # Spread attributes (`<X {...rest} />`) need a dedicated IR node;
          # surface as an Attribute marker for now so backends can flag.
          Attribute.new(name: "__spread__", value: Interpolation.new(expression: source_of(attr.argument)))
        end
      end

      def lower_jsx_attribute(attr)
        name = attr.attribute_name
        value = lower_attribute_value(attr.value)

        return StyleBinding.new(expression: style_binding_expression(attr.value)) if name == "className"

        Attribute.new(name: name, value: value)
      end

      def lower_attribute_value(value)
        case value
        when nil
          true
        when AST::JSXExpressionContainer
          Interpolation.new(expression: source_of(value.expression))
        else
          # Babel emits StringLiteral for `attr="literal"`. Read the raw
          # value rather than slicing source so we get the unquoted string.
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
