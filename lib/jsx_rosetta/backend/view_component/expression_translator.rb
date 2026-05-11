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
      #   * Names in `local_binding_names` (consts/destructures captured at
      #     lowering time but not modeled in IR) translate to a `nil`
      #     placeholder with an inline `# TODO: local 'name'` marker — the
      #     file still loads, but the reviewer sees what to fill in.
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
        UNARY = /\A(?<op>!+|-|\+)(?<operand>.+)\z/m
        SIMPLE_LITERALS = { "null" => "nil", "undefined" => "nil", "true" => "true", "false" => "false" }.freeze

        Result = Data.define(:ruby, :unresolved_identifiers)

        def initialize(prop_names:, local_binding_names: [])
          @prop_names = prop_names.to_set
          @local_binding_names = local_binding_names.to_set
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
          elsif (m = UNARY.match(source))
            translate_unary(m[:op], m[:operand], unresolved)
          end
        end

        def translate_unary(operator, operand, unresolved)
          inner = translate_ruby(operand.strip, unresolved)
          inner && "#{operator}#{inner}"
        end

        def in_local_scope?(name)
          @local_stack.any? { |scope| scope.include?(name) }
        end

        def translate_identifier(name, unresolved, member_chain_root: false)
          snake = AST::Inflector.underscore(name)
          if in_local_scope?(name)
            snake
          elsif @prop_names.include?(name)
            "@#{snake}"
          elsif @local_binding_names.include?(name)
            # We know this binding exists locally (destructure, hook tuple)
            # but can't model its value. As a leaf identifier, return `nil`
            # so the file loads (a bare snake_case ref would NameError).
            # As a member-chain root, `nil.member` would NoMethodError at
            # render time — worse. Fall back to the snake_case bare ref
            # and let it surface as a NameError (caller adds an unresolved
            # marker), which is at least debuggable. The TODO marker for
            # the binding source already lives in the comment block.
            if member_chain_root
              unresolved << name
              snake
            else
              "nil"
            end
          else
            unresolved << name
            snake
          end
        end

        def translate_member_chain(root, rest, unresolved)
          translated_root = translate_identifier(root, unresolved, member_chain_root: true)
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

          parts = []
          last_pos = 0
          content.to_enum(:scan, TEMPLATE_INTERPOLATION).each do
            match = ::Regexp.last_match
            literal = content[last_pos...match.begin(0)]
            parts << escape_ruby_string_literal(literal) unless literal.empty?
            parts << "\#{#{translate_template_interpolation(match[1], unresolved)}}"
            last_pos = match.end(0)
          end
          trailing = content[last_pos..]
          parts << escape_ruby_string_literal(trailing) unless trailing.empty?
          %("#{parts.join}")
        end

        # Split into literal vs. interpolation segments so `"` and `\` in
        # the literal parts can be escaped without touching the
        # interpolation expressions (which are already valid Ruby).
        def translate_template_interpolation(captured, unresolved)
          if (m = MEMBER_CHAIN.match(captured))
            translate_member_chain(m[:root], m[:rest], unresolved)
          else
            translate_identifier(captured, unresolved)
          end
        end

        # Escape backslashes and double quotes so the literal portions of a
        # translated template literal don't accidentally terminate the
        # surrounding Ruby string. Newlines stay literal — Ruby double-quoted
        # strings allow them, and template literals are typically used for
        # short interpolated phrases anyway.
        def escape_ruby_string_literal(text)
          text.gsub("\\", "\\\\").gsub('"', '\\"')
        end
      end
    end
  end
end
