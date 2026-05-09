# frozen_string_literal: true

require_relative "inflector"
require_relative "node"

module JsxRosetta
  module AST
    # Visitor base class. Subclasses define `visit_<snake_case_type>`
    # methods to handle specific Babel node types. Anything without a
    # dedicated handler falls through to `visit_default`, which by default
    # recurses into the node's children.
    #
    # Example:
    #   class TagCollector < JsxRosetta::AST::Visitor
    #     attr_reader :tags
    #     def initialize; @tags = []; super; end
    #
    #     def visit_jsx_element(node)
    #       @tags << node.tag_name
    #       visit_children(node)
    #     end
    #   end
    #
    #   collector = TagCollector.new
    #   collector.visit(parsed_file)
    class Visitor
      def visit(node)
        return unless node.is_a?(Node)

        method_name = "visit_#{Inflector.underscore(node.type)}"
        if respond_to?(method_name)
          public_send(method_name, node)
        else
          visit_default(node)
        end
      end

      def visit_default(node)
        visit_children(node)
      end

      def visit_children(node)
        node.each_child { |child| visit(child) }
      end
    end
  end
end
