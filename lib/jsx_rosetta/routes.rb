# frozen_string_literal: true

require_relative "ir/types"

module JsxRosetta
  # React Router → IR::RouteTree extraction. Recognizes the JSX-based
  # declarative form (<Routes><Route path="..." element={<X />} /></Routes>)
  # and the bare `<Route path="..." element={<X />} />` form anywhere in
  # the AST. The data-router form (createBrowserRouter([{ path, element }]))
  # is a future addition.
  module Routes
    def self.lower(ast_file)
      Lowering.new.lower(ast_file)
    end

    class Lowering
      def lower(ast_file)
        routes = []
        ast_file.walk do |node|
          next unless node.is_a?(AST::JSXElement)
          next unless node.tag_name == "Route"

          path = extract_path(node)
          element_name = extract_element_name(node)
          next if path.nil? || element_name.nil?

          routes << IR::RouteEntry.new(path: path, element_name: element_name)
        end
        IR::RouteTree.new(routes: routes)
      end

      private

      def find_attribute(element, name)
        element.opening_element.attributes.find do |attr|
          attr.is_a?(AST::JSXAttribute) && attr.attribute_name == name
        end
      end

      def extract_path(element)
        attr = find_attribute(element, "path")
        return nil unless attr

        value = attr.value
        case value
        when nil
          nil
        when AST::JSXExpressionContainer
          inner = value.expression
          inner.type == "StringLiteral" ? inner[:value] : nil
        else
          value.raw["value"] if value.raw["type"] == "StringLiteral"
        end
      end

      def extract_element_name(element)
        attr = find_attribute(element, "element")
        return nil unless attr.is_a?(AST::JSXAttribute)
        return nil unless attr.value.is_a?(AST::JSXExpressionContainer)

        inner = attr.value.expression
        return nil unless inner.is_a?(AST::JSXElement)

        flatten_element_name(inner.tag_name)
      end

      def flatten_element_name(tag_name)
        tag_name.to_s.split(".").last
      end
    end
  end
end
