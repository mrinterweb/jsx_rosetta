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
          .tr("-", "_")
          .downcase
      end

      def camelize(string)
        parts = string.split("_")
        parts[0] + parts[1..].map(&:capitalize).join
      end

      def upper_camelize(string)
        string.split("_").map(&:capitalize).join
      end

      # Emit a Ruby string literal in the rubocop-default single-quoted
      # form when safe. Falls back to `String#inspect` (double-quoted with
      # escapes) when the source contains characters that prevent the
      # single-quoted form: single quotes themselves, backslashes (Ruby
      # single-quoted strings only escape `\\` and `\'`), or control
      # characters (`\n`, `\t`, etc — single-quoted strings render those
      # literally). Non-ASCII characters (emojis, unicode) are fine in
      # single-quoted strings, so they don't force the fallback.
      def ruby_string_literal(value)
        str = value.to_s
        return str.inspect if str.include?("'") || str.include?("\\") || str.match?(/[\x00-\x1f\x7f]/)

        "'#{str}'"
      end
    end
  end
end
