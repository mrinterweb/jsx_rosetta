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
        # Tighter than `\A(['"])(.*)\1\z/m` — the greedy `.*` previously
        # matched expressions like `"X" ? "Y" : "Z"` as a single quoted
        # string. Now the body excludes unescaped quotes of the same kind,
        # so only true string literals match.
        STRING_LITERAL = /\A(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')\z/m
        NUMBER_LITERAL = /\A-?\d+(\.\d+)?\z/
        TEMPLATE_LITERAL = /\A`(.*)`\z/m
        TEMPLATE_INTERPOLATION = /\$\{([a-zA-Z_$][a-zA-Z_$0-9]*(?:\??\.[a-zA-Z_$][a-zA-Z_$0-9]*)*)\}/
        MEMBER_CHAIN = /\A(?<root>[a-zA-Z_$][a-zA-Z_$0-9]*)(?<rest>(?:\??\.[a-zA-Z_$][a-zA-Z_$0-9]*)+)\z/
        MEMBER_SEGMENT = /(\??\.)([a-zA-Z_$][a-zA-Z_$0-9]*)/
        # Class-component access patterns. `this.props.X` is the same shape as
        # a function-component prop reference, so it maps to `@x` plus any
        # trailing member chain. `this.state.X` has no Ruby analog (state
        # without a backing data source) so we surface a `nil` placeholder
        # with a TODO marker — the file still loads.
        THIS_PROPS_CHAIN = /\Athis\.props\.(?<rest>[a-zA-Z_$][a-zA-Z_$0-9]*(?:\??\.[a-zA-Z_$][a-zA-Z_$0-9]*)*)\z/
        THIS_STATE_CHAIN = /\Athis\.state\.(?<rest>[a-zA-Z_$][a-zA-Z_$0-9]*(?:\??\.[a-zA-Z_$][a-zA-Z_$0-9]*)*)\z/
        UNARY = /\A(?<op>!+|-|\+)(?<operand>.+)\z/m
        SIMPLE_LITERALS = { "null" => "nil", "undefined" => "nil", "true" => "true", "false" => "false" }.freeze

        # Binary operators we translate, grouped by precedence (lowest first).
        # We split on the *lowest*-precedence top-level operator and recurse
        # on each side, mirroring how a recursive-descent parser would treat
        # the source: `a > 0 && b < 5` splits on `&&` first, then each side
        # splits on its relational operator.
        #
        # Arithmetic operators (`+`, `-`, `*`, `/`, `%`) aren't included —
        # `-x` and `+x` are unary at the start of an operand, and string-
        # scanning can't disambiguate without operator-state tracking that
        # mirrors a parser. Real JSX conditions rarely need arithmetic in
        # tests; comparison + logical covers the bulk of them.
        BINARY_PRECEDENCE = [
          %w[|| ??],
          %w[&&],
          %w[=== !== == !=],
          %w[<= >= < >]
        ].freeze

        QUOTE_CHARS = ['"', "'", "`"].freeze
        OPEN_BRACKETS = ["(", "[", "{"].freeze
        CLOSE_BRACKETS = [")", "]", "}"].freeze

        Result = Data.define(:ruby, :unresolved_identifiers)

        # prop_aliases maps a local-binding name (the alias) to the
        # underlying prop name. `"data-testid": dataTestId` records
        # `{ "dataTestId" => "data-testid" }` so the use site of
        # `dataTestId` resolves to the prop's `@data_testid` ivar.
        def initialize(prop_names:, local_binding_names: [], prop_aliases: {})
          @prop_names = prop_names.to_set
          @local_binding_names = local_binding_names.to_set
          @prop_aliases = prop_aliases.dup
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
          source = unwrap_outer_parens(source.strip)
          translate_simple_form(source, unresolved) || translate_compound_form(source, unresolved)
        end

        # Handle the shapes that don't recurse: literals, identifiers, and
        # the class-component `this.props.X` / `this.state.X` accessors.
        # Returns nil when the source needs the compound-form dispatcher.
        def translate_simple_form(source, unresolved)
          return SIMPLE_LITERALS[source] if SIMPLE_LITERALS.key?(source)
          return source if source.match?(NUMBER_LITERAL)
          return reemit_string_literal(source) if source.match?(STRING_LITERAL)
          return translate_this_props_chain(::Regexp.last_match(:rest)) if THIS_PROPS_CHAIN.match(source)
          return translate_this_state_chain(::Regexp.last_match(:rest)) if THIS_STATE_CHAIN.match(source)
          return translate_identifier(source, unresolved) if source.match?(IDENTIFIER)

          nil
        end

        # Convert a JS string-literal source (`"foo"` or `'foo'`) into its
        # rubocop-preferred Ruby form: single-quoted when the body has no
        # escapes, embedded quotes of the matching kind, or non-printable
        # characters. Keeps the verbatim source otherwise — JS and Ruby
        # double-quoted escape sequences mostly overlap, so passing through
        # preserves semantics; rewriting `\n` from JS-single-quoted to Ruby
        # would corrupt the literal.
        def reemit_string_literal(source)
          quote = source[0]
          inner = source[1...-1]
          # Backslashes, embedded single quotes, and interpolation markers
          # all complicate the rewrite — keep the original literal as-is.
          # Non-ASCII (emojis, unicode) is fine in single-quoted Ruby
          # strings, so we don't bail for that.
          return source if inner.include?("\\") || inner.include?("'") ||
                           inner.include?("\#{") || inner.match?(/[\x00-\x1f\x7f]/)
          return source if quote == "'"

          "'#{inner}'"
        end

        # Handle the recursive / multi-segment shapes: member chains,
        # template literals, unary operators, and the binary fallthrough.
        def translate_compound_form(source, unresolved)
          if (m = MEMBER_CHAIN.match(source)) then translate_member_chain(m[:root], m[:rest], unresolved)
          elsif (m = TEMPLATE_LITERAL.match(source)) then translate_template_literal(m[1], unresolved)
          elsif (m = UNARY.match(source)) then translate_unary(m[:op], m[:operand], unresolved)
          else translate_binary(source, unresolved)
          end
        end

        # `this.props.X` → `@x` (plus any trailing member chain segments,
        # snake_cased and with `?.` → `&.`). The first segment IS the prop;
        # subsequent segments are accessed off the prop's value. We don't
        # add to `unresolved` here — class-component prop synthesis at
        # lowering time has already registered the name.
        def translate_this_props_chain(rest)
          first = rest.split(/\??\./, 2).first
          ivar = "@#{AST::Inflector.underscore(first)}"
          remainder = rest[first.length..]
          ruby_rest = remainder.gsub(MEMBER_SEGMENT) do
            op = ::Regexp.last_match(1) == "?." ? "&." : "."
            "#{op}#{AST::Inflector.underscore(::Regexp.last_match(2))}"
          end
          "#{ivar}#{ruby_rest}"
        end

        # `this.state.X` has no direct Ruby analog — class-component state
        # mutations don't map cleanly to a Phlex render. Emit `nil` so the
        # file loads; reviewers wire up real state via controller-passed
        # props or Stimulus values.
        def translate_this_state_chain(_rest)
          "nil"
        end

        def translate_unary(operator, operand, unresolved)
          operand_clean = operand.strip
          # `!fieldValue` where `fieldValue` is a known-but-unresolved local
          # would translate to `!nil` (always true) and silently flip the
          # condition's truthiness. Bail so the caller emits a TODO with
          # the verbatim source.
          return nil if unresolvable_local?(operand_clean)

          inner = translate_ruby(operand_clean, unresolved)
          inner && "#{operator}#{inner}"
        end

        # Walk source left-to-right looking for a top-level binary operator
        # at the lowest precedence level present. Split there and recurse on
        # each side. When two operators of the same precedence appear (e.g.
        # `a || b || c`), the rightmost is chosen — the recursion on `lhs`
        # then keeps splitting, yielding left-associative grouping.
        def translate_binary(source, unresolved)
          BINARY_PRECEDENCE.each do |operators|
            match = find_top_level_operator(source, operators)
            next unless match

            result = translate_binary_at(source, match, unresolved)
            return result if result
          end
          nil
        end

        def translate_binary_at(source, match, unresolved)
          start_idx, end_idx, js_op = match
          lhs = source[0...start_idx].strip
          rhs = source[end_idx..].strip
          return nil if lhs.empty? || rhs.empty?
          # `count > 0` where `count` is a known-but-unresolved local
          # translates to `nil > 0` and NoMethodErrors at render time.
          return nil if unresolvable_local?(lhs) || unresolvable_local?(rhs)

          lhs_ruby = translate_ruby(lhs, unresolved)
          rhs_ruby = translate_ruby(rhs, unresolved)
          return nil unless lhs_ruby && rhs_ruby
          # `value === null || value === undefined` both translate to
          # `@value.nil?` — collapse idempotent duplication for `||` / `&&`.
          return lhs_ruby if %w[|| &&].include?(js_op) && lhs_ruby == rhs_ruby

          rewrite_nil_comparison(lhs_ruby, rhs_ruby, js_op) ||
            "#{lhs_ruby} #{ruby_binary_operator(js_op)} #{rhs_ruby}"
        end

        # `x === null` / `x === undefined` → `x.nil?` (and `!==` → `!x.nil?`).
        # JSX commonly compares values against `null`/`undefined`; emitting
        # the literal `x == nil` form is valid Ruby but trips the
        # Style/NilComparison cop. The `.nil?` form is idiomatic and reads
        # better, so rewrite when either side is literally `nil`.
        def rewrite_nil_comparison(lhs_ruby, rhs_ruby, js_op)
          return nil unless %w[=== !== == !=].include?(js_op)

          if rhs_ruby == "nil" && lhs_ruby != "nil"
            js_op.start_with?("!") ? "!#{lhs_ruby}.nil?" : "#{lhs_ruby}.nil?"
          elsif lhs_ruby == "nil" && rhs_ruby != "nil"
            js_op.start_with?("!") ? "!#{rhs_ruby}.nil?" : "#{rhs_ruby}.nil?"
          end
        end

        def ruby_binary_operator(js_op)
          case js_op
          when "===" then "=="
          when "!==" then "!="
          when "??" then "||"
          else js_op
          end
        end

        # Scan `source` for the rightmost occurrence of any operator from
        # `operators` at lexical top level — outside any (), [], {}, or
        # string literal. Returns `[start_index, end_index, operator]` or nil.
        # Operators are tried longest-first at each position so `>=` beats
        # `>` and `===` beats `==`.
        def find_top_level_operator(source, operators)
          sorted_ops = operators.sort_by { |op| -op.length }
          state = { depth: 0, quote: nil, i: 0, last_match: nil }
          while state[:i] < source.length
            if state[:quote]
              advance_quoted(source, state)
            else
              scan_one_position(source, sorted_ops, state)
            end
          end
          state[:last_match]
        end

        def advance_quoted(source, state)
          c = source[state[:i]]
          if c == "\\"
            state[:i] += 2
          else
            state[:quote] = nil if c == state[:quote]
            state[:i] += 1
          end
        end

        def scan_one_position(source, sorted_ops, state)
          c = source[state[:i]]
          if QUOTE_CHARS.include?(c)
            state[:quote] = c
            state[:i] += 1
            return
          end
          state[:depth] += 1 if OPEN_BRACKETS.include?(c)
          state[:depth] -= 1 if CLOSE_BRACKETS.include?(c)

          matched = state[:depth].zero? && sorted_ops.find { |op| source[state[:i], op.length] == op }
          if matched
            state[:last_match] = [state[:i], state[:i] + matched.length, matched]
            state[:i] += matched.length
          else
            state[:i] += 1
          end
        end

        # Strip a single layer of outer parens when they wrap the entire
        # source (`(a > b)` → `a > b`). When the leading `(` closes mid-
        # source — e.g. `(a > b) && c` — leave the source alone since the
        # parens are structurally meaningful. Trims surrounding whitespace.
        def unwrap_outer_parens(source)
          return source unless source.start_with?("(") && source.end_with?(")")
          return source unless outer_parens_balanced?(source)

          source[1...-1].strip
        end

        def outer_parens_balanced?(source)
          depth = 0
          quote = nil
          source.each_char.with_index do |c, i|
            if quote
              quote = nil if c == quote && source[i - 1] != "\\"
              next
            end
            quote = c if QUOTE_CHARS.include?(c)
            depth += 1 if c == "("
            if c == ")"
              depth -= 1
              return false if depth.zero? && i != source.length - 1
            end
          end
          true
        end

        def in_local_scope?(name)
          @local_stack.any? { |scope| scope.include?(name) }
        end

        def translate_identifier(name, unresolved, member_chain_root: false)
          snake = AST::Inflector.underscore(name)
          if in_local_scope?(name)
            snake
          elsif @prop_aliases.key?(name)
            "@#{AST::Inflector.underscore(@prop_aliases[name])}"
          elsif @prop_names.include?(name)
            "@#{snake}"
          elsif @local_binding_names.include?(name)
            # We know this binding exists locally (destructure, hook tuple)
            # but can't model its value. As a leaf identifier, return `nil`
            # so the file loads (a bare snake_case ref would NameError).
            # As a member-chain root, `nil.member` would NoMethodError and
            # the bare-snake fallback would NameError — both crash at render
            # time. Bail so the whole expression fails translation and the
            # caller emits a TODO comment with the verbatim source.
            return nil if member_chain_root

            "nil"
          else
            unresolved << name
            snake
          end
        end

        # An identifier that we know to be a local binding (e.g. destructured
        # from an untranslatable init) but whose value we can't model. The
        # leaf-translates-to-nil path is safe in value positions (attribute
        # kwargs, leaf interpolations) but compound contexts (unary, binary,
        # member chain) must bail so callers emit a TODO instead of silently
        # changing semantics.
        def unresolvable_local?(source)
          return false unless source.match?(IDENTIFIER)

          @local_binding_names.include?(source) &&
            !in_local_scope?(source) &&
            !@prop_names.include?(source)
        end

        def translate_member_chain(root, rest, unresolved)
          translated_root = translate_identifier(root, unresolved, member_chain_root: true)
          return nil unless translated_root

          # Underscore each chain segment so JS camelCase identifiers map to
          # Ruby snake_case (`post.coverImage` → `post.cover_image`). Map
          # optional-chaining `?.` to Ruby's safe-nav `&.` so a nil receiver
          # short-circuits to nil instead of raising NoMethodError.
          ruby_rest = rest.gsub(MEMBER_SEGMENT) do
            op = ::Regexp.last_match(1) == "?." ? "&." : "."
            "#{op}#{AST::Inflector.underscore(::Regexp.last_match(2))}"
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
            translated = translate_template_interpolation(match[1], unresolved)
            # An interpolation segment that itself fails translation (nil)
            # or resolves to literal `nil` (known-but-unresolvable local)
            # would emit `\#{}` / `\#{nil}` — empty or semantically empty
            # interpolation that rubocop flags and that loses the source's
            # intent. Bail so the whole template literal falls through to
            # the caller's TODO path with the verbatim JS source visible.
            return nil if translated.nil? || translated == "nil"

            parts << "\#{#{translated}}"
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
