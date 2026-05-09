# frozen_string_literal: true

require_relative "../../ast/inflector"

module JsxRosetta
  module Backend
    class ViewComponent
      # Best-effort, narrowly-scoped JS-to-Ruby translation for the simple
      # expression shapes that JSX components in real codebases use most
      # often: bare identifiers, literals, and template literals composed
      # of string parts plus identifier interpolations. Anything more
      # complex (function calls, conditionals, member expressions) returns
      # `nil` from `#translate` so the backend can emit a TODO marker
      # and fall back to the verbatim JS source.
      #
      # Identifier names are looked up against a known set of component
      # prop names; matched names become Ruby instance variables (`@name`),
      # everything else is left bare and flagged.
      class ExpressionTranslator
        IDENTIFIER = /\A[a-zA-Z_$][a-zA-Z_$0-9]*\z/
        STRING_LITERAL = /\A(['"])(.*)\1\z/m
        NUMBER_LITERAL = /\A-?\d+(\.\d+)?\z/
        TEMPLATE_LITERAL = /\A`(.*)`\z/m
        TEMPLATE_INTERPOLATION = /\$\{([a-zA-Z_$][a-zA-Z_$0-9]*)\}/
        SIMPLE_LITERALS = { "null" => "nil", "undefined" => "nil", "true" => "true", "false" => "false" }.freeze

        Result = Data.define(:ruby, :unresolved_identifiers)

        def initialize(prop_names:)
          @prop_names = prop_names.to_set
        end

        # Translate a JS expression source string to a Ruby expression.
        # Returns a Result, or nil if the expression isn't a recognized
        # simple shape.
        def translate(source)
          source = source.strip
          unresolved = []

          ruby =
            if SIMPLE_LITERALS.key?(source) then SIMPLE_LITERALS[source]
            elsif source.match?(NUMBER_LITERAL) || source.match?(STRING_LITERAL) then source
            elsif source.match?(IDENTIFIER) then translate_identifier(source, unresolved)
            elsif (m = TEMPLATE_LITERAL.match(source)) then translate_template_literal(m[1], unresolved)
            end

          ruby && Result.new(ruby: ruby, unresolved_identifiers: unresolved.uniq)
        end

        private

        def translate_identifier(name, unresolved)
          snake = AST::Inflector.underscore(name)
          if @prop_names.include?(name)
            "@#{snake}"
          else
            unresolved << name
            snake
          end
        end

        def translate_template_literal(content, unresolved)
          return nil if content.include?("\\`")
          return nil if content.scan("${").size != content.scan(TEMPLATE_INTERPOLATION).size

          ruby_content = content.gsub(TEMPLATE_INTERPOLATION) do |_match|
            ident = ::Regexp.last_match(1)
            translated = translate_identifier(ident, unresolved)
            "\#{#{translated}}"
          end
          %("#{ruby_content}")
        end
      end
    end
  end
end
