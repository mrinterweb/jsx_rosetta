# frozen_string_literal: true

require_relative "node"

module JsxRosetta
  module AST
    # Subclasses for the Babel node types where named accessors carry their
    # weight (mostly the JSX subtree). Other Babel types fall through to the
    # generic Node class — they're still walkable, pattern-matchable, and
    # field-addressable, just without bespoke methods.
    #
    # As lowering passes need more ergonomic access to specific node fields,
    # add a class here. Don't pre-emptively wrap every Babel type.

    class File < Node
      register "File"

      def program
        self[:program]
      end
    end

    class Program < Node
      register "Program"

      def body
        self[:body]
      end

      def source_type
        @raw["sourceType"]
      end
    end

    class JSXElement < Node
      register "JSXElement"

      def opening_element
        self[:opening_element]
      end

      def closing_element
        self[:closing_element]
      end

      def jsx_children
        self[:children]
      end

      def tag_name
        opening_element&.tag_name
      end

      def self_closing?
        opening_element&.self_closing? || false
      end
    end

    class JSXOpeningElement < Node
      register "JSXOpeningElement"

      def name
        self[:name]
      end

      def attributes
        self[:attributes]
      end

      def tag_name
        node_to_tag_name(name)
      end

      def self_closing?
        @raw["selfClosing"] == true
      end

      private

      def node_to_tag_name(node)
        case node
        when JSXIdentifier then node.name
        when JSXMemberExpression, JSXNamespacedName then node.qualified_name
        end
      end
    end

    class JSXClosingElement < Node
      register "JSXClosingElement"

      def name
        self[:name]
      end
    end

    class JSXIdentifier < Node
      register "JSXIdentifier"

      def name
        @raw["name"]
      end
    end

    class JSXMemberExpression < Node
      register "JSXMemberExpression"

      def object
        self[:object]
      end

      def property
        self[:property]
      end

      def qualified_name
        "#{object_name}.#{property.name}"
      end

      private

      def object_name
        case object
        when JSXIdentifier then object.name
        when JSXMemberExpression then object.qualified_name
        end
      end
    end

    class JSXNamespacedName < Node
      register "JSXNamespacedName"

      def namespace
        self[:namespace]
      end

      def name
        self[:name]
      end

      def qualified_name
        "#{namespace.name}:#{name.name}"
      end
    end

    class JSXAttribute < Node
      register "JSXAttribute"

      def name
        self[:name]
      end

      def value
        self[:value]
      end

      def attribute_name
        case (attr_name = name)
        when JSXIdentifier then attr_name.name
        when JSXNamespacedName then attr_name.qualified_name
        end
      end
    end

    class JSXSpreadAttribute < Node
      register "JSXSpreadAttribute"

      def argument
        self[:argument]
      end
    end

    class JSXExpressionContainer < Node
      register "JSXExpressionContainer"

      def expression
        self[:expression]
      end
    end

    class JSXSpreadChild < Node
      register "JSXSpreadChild"

      def expression
        self[:expression]
      end
    end

    class JSXText < Node
      register "JSXText"

      def value
        @raw["value"]
      end
    end

    class JSXEmptyExpression < Node
      register "JSXEmptyExpression"
    end

    class JSXFragment < Node
      register "JSXFragment"

      def opening_fragment
        self[:opening_fragment]
      end

      def closing_fragment
        self[:closing_fragment]
      end

      def jsx_children
        self[:children]
      end
    end

    class JSXOpeningFragment < Node
      register "JSXOpeningFragment"
    end

    class JSXClosingFragment < Node
      register "JSXClosingFragment"
    end
  end
end
