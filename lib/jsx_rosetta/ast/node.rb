# frozen_string_literal: true

require_relative "inflector"

module JsxRosetta
  module AST
    # Base class for every Babel-shaped AST node. Wraps the raw JSON hash
    # and provides:
    #   * Field access via `node[:opening_element]` (snake_case symbols or
    #     camelCase strings — both resolve to the same field).
    #   * Source location accessors (`loc`, `range`, `start_pos`, `end_pos`).
    #   * Tree traversal via `each_child` / `walk`.
    #   * Pattern-matching support via `deconstruct_keys`.
    #
    # Specific Babel node types may register subclasses that add named
    # accessors (e.g. JSXElement#opening_element). Unknown types fall
    # through to the generic Node class so the parser doesn't crash on
    # ESNext additions.
    class Node
      TYPE_REGISTRY = {} # rubocop:disable Style/MutableConstant

      attr_reader :raw

      def self.register(*type_names)
        type_names.each { |name| TYPE_REGISTRY[name] = self }
      end

      def self.wrap(value)
        case value
        when Hash
          if value.key?("type")
            klass = TYPE_REGISTRY.fetch(value["type"], Node)
            klass.new(value)
          else
            value
          end
        when Array
          value.map { |element| wrap(element) }
        else
          value
        end
      end

      def initialize(raw)
        @raw = raw
      end

      def type
        @raw["type"]
      end

      def loc
        @raw["loc"]
      end

      def range
        @raw["range"]
      end

      def start_pos
        @raw["start"]
      end

      def end_pos
        @raw["end"]
      end

      # Field access. Accepts snake_case symbols/strings (translated to
      # camelCase) and camelCase strings (used verbatim).
      def [](key)
        raw_key = key.to_s
        return Node.wrap(@raw[raw_key]) if @raw.key?(raw_key)

        camel_key = Inflector.camelize(raw_key)
        Node.wrap(@raw[camel_key])
      end

      def dig(*keys)
        keys.reduce(self) do |current, key|
          break nil if current.nil?

          current[key]
        end
      end

      def each_child(&block)
        return enum_for(:each_child) unless block

        @raw.each_value { |value| yield_descendant_nodes(value, &block) }
      end

      def children
        each_child.to_a
      end

      def walk(&block)
        return enum_for(:walk) unless block

        yield self
        each_child { |child| child.walk(&block) }
      end

      # Pattern-matching support. Returns a hash with snake_case symbol
      # keys; values are wrapped (Node instances or arrays of Node/raw values).
      def deconstruct_keys(keys)
        if keys.nil?
          @raw.each_with_object({}) do |(k, v), out|
            out[Inflector.underscore(k).to_sym] = Node.wrap(v)
          end
        else
          keys.each_with_object({}) do |key, out|
            camel_key = Inflector.camelize(key.to_s)
            actual_key = @raw.key?(key.to_s) ? key.to_s : camel_key
            out[key] = Node.wrap(@raw[actual_key]) if @raw.key?(actual_key)
          end
        end
      end

      def ==(other)
        other.is_a?(Node) && other.raw == @raw
      end
      alias eql? ==

      def hash
        @raw.hash
      end

      def inspect
        "#<#{self.class.name || "JsxRosetta::AST::Node"} type=#{type.inspect} loc=#{loc_summary}>"
      end

      private

      def yield_descendant_nodes(value, &block)
        case value
        when Hash
          yield Node.wrap(value) if value.key?("type")
        when Array
          value.each { |element| yield_descendant_nodes(element, &block) }
        end
      end

      def loc_summary
        return "?" unless loc

        start_loc = loc["start"] || {}
        "#{start_loc["line"]}:#{start_loc["column"]}"
      end
    end
  end
end
