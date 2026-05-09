# frozen_string_literal: true

module JsxRosetta
  module AST
    # Internal helpers for converting between Babel's camelCase field names
    # and Ruby's snake_case conventions.
    module Inflector
      module_function

      def underscore(string)
        string
          .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
          .gsub(/([a-z\d])([A-Z])/, '\1_\2')
          .downcase
      end

      def camelize(string)
        parts = string.split("_")
        parts[0] + parts[1..].map(&:capitalize).join
      end
    end
  end
end
