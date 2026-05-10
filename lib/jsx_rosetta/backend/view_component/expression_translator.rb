# frozen_string_literal: true

require_relative "../../ast/inflector"

module JsxRosetta
  module Backend
    class ViewComponent
      # Best-effort, narrowly-scoped JS-to-Ruby translation for the simple
      # expression shapes that JSX components in real codebases use most
      # often: bare identifiers, literals, simple member-expression chains
      # (`item.label`), and template literals composed of identifier
      # interpolations. Anything more complex (function calls, conditionals,
      # subscripts) returns `nil` from `#translate` so the backend can emit
      # a TODO marker and fall back to the verbatim JS source.
      #
      # Identifier resolution:
      #   * Names in the active local scope (e.g. loop bindings) translate
      #     to the bare snake_case identifier.
      #   * Names in `prop_names` translate to a `@snake_case` instance
      #     variable.
      #   * Anything else translates to the bare snake_case identifier and
      #     is recorded as unresolved.
      #
      # Local scopes can be pushed via `with_locals` and stack — each
      # entry shadows lower entries.
      class ExpressionTranslator
        IDENTIFIER = /\A[a-zA-Z_$][a-zA-Z_$0-9]*\z/
        STRING_LITERAL = /\A(['"])(.*)\1\z/m
        NUMBER_LITERAL = /\A-?\d+(\.\d+)?\z/
        TEMPLATE_LITERAL = /\A`(.*)`\z/m
        TEMPLATE_INTERPOLATION = /\$\{([a-zA-Z_$][a-zA-Z_$0-9]*(?:\.[a-zA-Z_$][a-zA-Z_$0-9]*)*)\}/
        MEMBER_CHAIN = /\A(?<root>[a-zA-Z_$][a-zA-Z_$0-9]*)(?<rest>(?:\.[a-zA-Z_$][a-zA-Z_$0-9]*)+)\z/
        SIMPLE_LITERALS = { "null" => "nil", "undefined" => "nil", "true" => "true", "false" => "false" }.freeze

        Result = Data.define(:ruby, :unresolved_identifiers)

        def initialize(prop_names:)
          @prop_names = prop_names.to_set
          @local_stack = []
        end

        def with_locals(names)
          @local_stack.push(names.compact)
          yield
        ensure
          @local_stack.pop
        end

        def translate(source)
          source = source.strip
          unresolved = []

          ruby = translate_ruby(source, unresolved)
          ruby && Result.new(ruby: ruby, unresolved_identifiers: unresolved.uniq)
        end

        private

        def translate_ruby(source, unresolved)
          if SIMPLE_LITERALS.key?(source) then SIMPLE_LITERALS[source]
          elsif source.match?(NUMBER_LITERAL) || source.match?(STRING_LITERAL) then source
          elsif source.match?(IDENTIFIER) then translate_identifier(source, unresolved)
          elsif (m = MEMBER_CHAIN.match(source)) then translate_member_chain(m[:root], m[:rest], unresolved)
          elsif (m = TEMPLATE_LITERAL.match(source)) then translate_template_literal(m[1], unresolved)
          end
        end

        def in_local_scope?(name)
          @local_stack.any? { |scope| scope.include?(name) }
        end

        def translate_identifier(name, unresolved)
          snake = AST::Inflector.underscore(name)
          if in_local_scope?(name)
            snake
          elsif @prop_names.include?(name)
            "@#{snake}"
          else
            unresolved << name
            snake
          end
        end

        def translate_member_chain(root, rest, unresolved)
          translated_root = translate_identifier(root, unresolved)
          # Underscore each chain segment so JS camelCase identifiers map to
          # Ruby snake_case (`post.coverImage` → `post.cover_image`).
          ruby_rest = rest.gsub(/\.([a-zA-Z_$][a-zA-Z_$0-9]*)/) do
            ".#{AST::Inflector.underscore(::Regexp.last_match(1))}"
          end
          "#{translated_root}#{ruby_rest}"
        end

        def translate_template_literal(content, unresolved)
          return nil if content.include?("\\`")
          return nil if content.scan("${").size != content.scan(TEMPLATE_INTERPOLATION).size

          ruby_content = content.gsub(TEMPLATE_INTERPOLATION) do |_match|
            captured = ::Regexp.last_match(1)
            translated = if (m = MEMBER_CHAIN.match(captured))
                           translate_member_chain(m[:root], m[:rest], unresolved)
                         else
                           translate_identifier(captured, unresolved)
                         end
            "\#{#{translated}}"
          end
          %("#{ruby_content}")
        end
      end
    end
  end
end
