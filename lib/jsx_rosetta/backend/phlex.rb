# frozen_string_literal: true

require_relative "../ast/inflector"
require_relative "../ir/types"
require_relative "base"
require_relative "view_component/expression_translator"

module JsxRosetta
  module Backend
    # Emits a Phlex 2.x view class (one Ruby file per component) from
    # an IR::Component. Single-file output by design — the JSX `<h1>...`
    # template lives as Ruby inside `view_template`, not in a sibling
    # .erb. When the source uses `onClick`/`onChange` etc., a sibling
    # Stimulus controller `_controller.js` is emitted alongside (same
    # convention as the ViewComponent backend).
    #
    # Naming strategies (mutually exclusive):
    #   default                  class FlashyHeader < Phlex::HTML
    #   suffix: "Component"      class FlashyHeaderComponent < Phlex::HTML
    #   namespace: "Components"  module Components
    #                              class FlashyHeader < Phlex::HTML
    #
    # Hyphenated attributes (`data-testid`, `aria-label`, etc.) emit as
    # string-keyed hash entries inside a splat — `**{ "data-testid" => @x }`
    # — since Ruby kwargs can't carry hyphens. Snake_case-friendly attrs
    # emit as regular keyword arguments.
    class Phlex < Base
      DEFAULT_SLOT_NAME = "children"
      DEFAULT_SUFFIX = "Component"
      PHLEX_BASE_CLASS = "Phlex::HTML"
      VALID_IDENTIFIER = /\A[a-z_][a-z0-9_]*\z/i
      VOID_ELEMENTS = %w[area base br col embed hr img input link meta param source track wbr].freeze

      # Inline budget for object/array literal rendering. When the
      # single-line rendering of a literal exceeds this width — measured
      # from the opening bracket — it switches to a multi-line layout
      # with one entry per line, indented two spaces past the parent's
      # line indent. Closing bracket re-aligns to the parent indent.
      # Chosen to keep typical attr lines under ~120 chars after the
      # kwarg name and surrounding `render Foo.new(...)` wrapper.
      LITERAL_INLINE_BUDGET = 80

      # Per-library TODO header lines surfaced above the verbatim hook
      # source. Each library has a different Rails analog, so we don't
      # collapse them into a single generic block. Keys must mirror the
      # `:library` values produced by IR::Lowering.
      HOOK_TODO_HEADERS = {
        react: [
          "TODO: React hooks detected. None translate automatically.",
          "Hotwire/Stimulus handles behavior; controllers/views handle state;",
          "turbo-frames handle async loading. Original source:"
        ].freeze,
        apollo: [
          "TODO: Apollo data-fetching hooks detected. None translate automatically.",
          "Move the fetch to the Rails controller (or a model/service); pass the",
          "result in as a prop. For useMutation, use a form POST + redirect or a",
          "Turbo Stream response. Original source:"
        ].freeze,
        next_js: [
          "TODO: Next.js navigation hooks detected. None translate automatically.",
          "Rails analogs: useRouter -> redirect_to / form actions;",
          "usePathname -> request.path; useSearchParams / useParams -> params;",
          "useSelectedLayoutSegment(s) -> match against request.path in the view.",
          "Original source:"
        ].freeze
      }.freeze

      # Structured intermediate for the data-action attribute — mirrors the
      # ViewComponent backend pattern (lib/jsx_rosetta/backend/view_component.rb).
      EventDescriptor = Data.define(:kind, :body)

      def initialize(suffix: nil, namespace: nil)
        super()
        raise ArgumentError, "Phlex backend: pass either suffix: or namespace:, not both" if suffix && namespace

        @suffix = suffix.is_a?(String) ? suffix : (DEFAULT_SUFFIX if suffix == true)
        @namespace = namespace
      end

      def emit(component, source_filename: nil)
        translator = build_translator(component)
        @stimulus_identifier = component.stimulus_methods.any? ? stimulus_identifier(component) : nil
        @lambda_methods = []
        @lambda_method_counts = {}
        @event_handler_methods = []
        @emit_module_prefix = first_emit_for_module_bindings?(component)
        @source_filename = source_filename

        files = [File.new(path: ruby_path(component), contents: clean_output(render_ruby_class(component, translator)))]
        if component.stimulus_methods.any?
          files << File.new(
            path: stimulus_path(component),
            contents: render_stimulus_controller_js(component)
          )
        end
        files
      end

      # When a source file lowers to multiple sibling components, lower_all
      # attaches the *same* module_bindings array to every sibling. Emitting
      # the constants TODO block on each one duplicates 40-line GraphQL
      # blocks across every emitted .rb file. Track the array identities
      # we've seen and only emit the prefix the first time.
      def first_emit_for_module_bindings?(component)
        return true if component.module_bindings.empty?

        @seen_module_bindings ||= Set.new
        key = component.module_bindings.object_id
        return false if @seen_module_bindings.include?(key)

        @seen_module_bindings << key
        true
      end

      def build_translator(component)
        prop_names = component.props.map(&:name)
        prop_names << component.rest_prop_name if component.rest_prop_name
        prop_aliases = component.props.each_with_object({}) do |prop, hash|
          hash[prop.alias_name] = prop.name if prop.alias_name
        end
        # `imported_names` covers both top-level `import` declarations AND
        # top-level helper bindings (`function onError(){}`, `const FOO = …`).
        # They behave identically at the use site — the translator bails out
        # to `nil` rather than emitting a bare snake_case ref that NameErrors.
        ViewComponent::ExpressionTranslator.new(
          prop_names: prop_names,
          local_binding_names: component.local_binding_names,
          prop_aliases: prop_aliases,
          imported_names: component.module_imports.map(&:name) + component.module_bindings.map(&:name)
        )
      end

      # Strip trailing whitespace from each emitted line — easier than
      # threading rstrip through every formatting helper, and a single
      # source of truth keeps Layout/TrailingWhitespace at zero. Preserve
      # the trailing newline of the file as-is. Also suppresses the
      # intentional-`if false` cops file-wide so the user's rubocop
      # doesn't drown out actionable findings.
      def clean_output(source)
        cleaned = "#{source.split("\n").map(&:rstrip).join("\n")}\n".sub(/\n\n+\z/, "\n")
        suppress_intentional_if_false_cops(cleaned)
      end

      # When the file contains any `if false` / `elsif false` branch (the
      # fallback we emit when a JSX condition can't be translated to Ruby),
      # disable the cops that flag those at file scope. The corresponding
      # `# TODO: translate condition:` comment already names the issue, so
      # the cop's report is redundant noise. Only emits when needed.
      def suppress_intentional_if_false_cops(source)
        cops = []
        cops << "Lint/LiteralAsCondition" if source.match?(/^\s*(?:if|elsif) false$/m)
        # An elsif-false adjacent to its leading `if false` is the only
        # configuration that triggers DuplicateElsifCondition — multiple
        # `if false`s in separate scopes don't qualify. The pattern below
        # matches an `if false` directly followed (after consequent lines)
        # by an `elsif false` at the same indent.
        cops << "Lint/DuplicateElsifCondition" if source.match?(/^(\s*)if false\b[\s\S]*?^\1elsif false\b/m)
        return source if cops.empty?

        disable = "# rubocop:disable #{cops.join(", ")}\n\n"
        enable = "# rubocop:enable #{cops.join(", ")}\n"
        # Magic comment must be followed by a blank line before any other
        # comment (Layout/EmptyLineAfterMagicComment), and every file-level
        # disable needs a matching enable (Lint/MissingCopEnableDirective).
        with_disable = source.sub(/^# frozen_string_literal: true\n\n/,
                                  "# frozen_string_literal: true\n\n#{disable}")
        "#{with_disable.chomp}\n#{enable}"
      end

      private

      # JSX-returning lowercase helpers (e.g. `textRender`, `getNodeIcon`)
      # have lowercase-starting names. Ruby class names must be constants
      # (begin with an uppercase letter), so we capitalize the first
      # letter when forming the class name. Pure-PascalCase names pass
      # through unchanged.
      def class_name(component)
        base = "#{component.name[0].upcase}#{component.name[1..]}"
        suffix = effective_suffix_for(base, source_filename: @source_filename)
        suffix ? "#{base}#{suffix}" : base
      end

      # Pick the suffix to append to a class name, applying two rules in
      # order:
      #
      # 1. **Page detection.** Source name ends in `Page` OR the source
      #    file path contains `/pages/` (Next.js / Nuxt convention) →
      #    use the literal `Page` suffix, regardless of the configured
      #    `@suffix`. Lets the gem keep `<HomePage>` / `pages/home.tsx`
      #    landing as `HomePage` / `home_page.rb` even when the user
      #    passes `--phlex-suffix=Component` for the rest of the codebase.
      # 2. **No double-suffix.** When the name already ends with the
      #    chosen suffix (e.g. source `HomePage` with the `Page` suffix,
      #    or source `FooComponent` with the `Component` suffix), skip
      #    the append. Returns nil so callers don't concatenate.
      #
      # `source_filename` is the absolute or repo-relative path of the
      # JSX source; nil when callers translate raw source strings
      # without filename context (then only the name-based signal fires).
      def effective_suffix_for(name, source_filename: nil)
        suffix = page?(name, source_filename) ? "Page" : @suffix
        return nil unless suffix
        return nil if name.end_with?(suffix)

        suffix
      end

      def page?(name, source_filename)
        return true if name.end_with?("Page")
        return false unless source_filename

        source_filename.include?("/pages/")
      end

      def ruby_path(component)
        "#{AST::Inflector.underscore(class_name(component))}.rb"
      end

      def stimulus_path(component)
        "#{AST::Inflector.underscore(class_name(component))}_controller.js"
      end

      def stimulus_identifier(component)
        AST::Inflector.underscore(component.name).tr("_", "-")
      end

      def render_ruby_class(component, translator)
        class_body = render_class_body(component, translator)
        prefix = render_module_bindings_prefix(component)
        wrap_in_namespace("#{prefix}#{class_body}")
      end

      # Top-level `const`/`let` declarations outside the component
      # function — captured at lowering time and surfaced here as a TODO
      # comment block above the class definition. We don't try to
      # translate the JS; the human reviewer either copies the value as
      # a Ruby constant or moves it to a Rails initializer.
      def render_module_bindings_prefix(component)
        return "" if component.module_bindings.empty?
        # Sibling components from the same source file share the same
        # module_bindings list; emit the prefix only on the first sibling
        # so a 40-line GraphQL TODO doesn't appear in every sibling file.
        return "" unless @emit_module_prefix

        lines = ["# TODO: module-level constants — translate to Ruby constants " \
                 "or move to a Rails initializer:"]
        component.module_bindings.each { |b| lines.concat(comment_lines(b.source)) }
        "#{lines.join("\n")}\n"
      end

      def wrap_in_namespace(body)
        return "# frozen_string_literal: true\n\n#{body}" unless @namespace

        indented = body.lines.map { |line| line.strip.empty? ? line : "  #{line}" }.join
        "# frozen_string_literal: true\n\nmodule #{@namespace}\n#{indented}end\n"
      end

      def render_class_body(component, translator)
        initializer = render_initializer(component, translator)
        template = if component.mode == :data_factory
                     render_data_factory_method(component, translator)
                   else
                     render_view_template(component, translator)
                   end
        # Render private methods (render_methods + lambdas) AFTER the
        # template — `@lambda_methods` is populated during attribute-value
        # rendering, and render_methods bodies share the same indent.
        private_section = render_private_methods(component, translator)

        sections = [initializer, template, private_section].compact.join("\n\n")
        cls = class_name(component)
        # One-line docstring above the class — pacifies Style/Documentation
        # without forcing the host project to disable the cop globally. The
        # body is intentionally minimal so it doesn't drift from the source
        # over time; a richer comment belongs in the host repo's review.
        "# #{cls} — generated by jsx_rosetta from JSX. Review before shipping.\n" \
          "class #{cls} < #{PHLEX_BASE_CLASS}\n#{sections}\nend\n"
      end

      # For data-factory components (`export const createColumns = (args)
      # => [{...}, {...}]`) emit a public method that returns the
      # translated data array. The method name is the snake_case of the
      # original JS identifier (`createColumns` → `create_columns`).
      # Param names come from the regular `props:` list so callers can
      # invoke with keyword arguments matching the JS signature.
      def render_data_factory_method(component, translator)
        method_name = AST::Inflector.underscore(component.name)
        param_names = component.props.map(&:name)
        signature = data_factory_signature(method_name, param_names)
        # Param refs translate as locals (`token`) inside the body rather
        # than as ivars (`@token`) — the factory params are method-local,
        # not constructor-stored. `with_locals` pushes the JS names onto
        # the translator's local stack for the duration of the body.
        body = translator.with_locals(param_names) do
          render_inline_value(component.body, translator, todos: [], attr_name: nil, indent: 4)
        end
        "  def #{signature}\n    #{body}\n  end"
      end

      def data_factory_signature(method_name, param_names)
        return method_name if param_names.empty?

        kwargs = param_names.map { |name| "#{AST::Inflector.underscore(name)}: nil" }
        "#{method_name}(#{kwargs.join(", ")})"
      end

      # Coalesce RenderMethod (from local-arrow extraction) and Lambda
      # (from Gap H object-literal extraction) into one `private` section.
      # Emitting `private` twice is harmless but ugly; one block reads
      # cleaner.
      def render_private_methods(component, translator)
        render_methods = component.render_methods.map { |rm| render_render_method_definition(rm, translator) }
        lambda_methods = (@lambda_methods || []).map do |entry|
          render_lambda_method_definition(entry[:method_name], entry[:lambda], translator)
        end
        event_handlers = (@event_handler_methods || []).map do |entry|
          render_event_handler_method_definition(entry[:method_name], entry[:handler], entry[:attr_name])
        end
        all = render_methods + lambda_methods + event_handlers
        return nil if all.empty?

        "  private\n\n#{all.join("\n\n")}"
      end

      # Emit one EventHandler as a stub method on the class. The JS body
      # is preserved verbatim as a TODO comment; the method itself is a
      # no-op so the file loads and the receiving component sees a real
      # `Method` object via `method(:name)`. Parameter names snake_case
      # from JS conventions to Ruby identifiers.
      def render_event_handler_method_definition(method_name, handler, attr_name)
        snake_params = handler.params.map { |p| AST::Inflector.underscore(p) }
        signature = snake_params.empty? ? method_name : "#{method_name}(#{snake_params.join(", ")})"
        body_lines = comment_lines(handler.body_source).map { |l| "    #{l}" }
        [
          "  def #{signature}",
          "    # TODO: translate the original JSX `#{attr_name}` handler:",
          *body_lines,
          "  end"
        ].join("\n")
      end

      # Emit one RenderMethod as a private method on the class. Params are
      # pushed into the translator scope so identifier references inside
      # the body resolve to method-local arguments.
      def render_render_method_definition(render_method, translator)
        snake_params = render_method.params.map { |p| AST::Inflector.underscore(p) }
        signature = snake_params.empty? ? render_method.name : "#{render_method.name}(#{snake_params.join(", ")})"
        body = translator.with_locals(render_method.params) do
          render_ir_node(render_method.body, translator, indent: 4)
        end
        "  def #{signature}\n#{body}\n  end"
      end

      def render_lambda_method_definition(method_name, lambda, translator)
        snake_params = lambda.params.map { |p| AST::Inflector.underscore(p) }
        signature = snake_params.empty? ? method_name : "#{method_name}(#{snake_params.join(", ")})"
        body = translator.with_locals(lambda.params) do
          render_ir_node(lambda.body, translator, indent: 4)
        end
        "  def #{signature}\n#{body}\n  end"
      end

      def render_initializer(component, translator)
        # Data-factory components consume their params as method args, not
        # as constructor props — skip the initializer entirely.
        return nil if component.mode == :data_factory

        props = initializable_props(component)
        rest_name = component.rest_prop_name
        return nil if props.empty? && rest_name.nil?

        # Snake-case the rest-name kwarg so it matches the snake_case ivar
        # the body uses (`**(@description_props || {})`). Emitting the
        # camelCase JS name straight to the kwarg would create a different
        # ivar than the body reads, silently dropping the splat's contents.
        rest_snake = rest_name && AST::Inflector.underscore(rest_name)
        kwargs = props.map { |prop| ruby_kwarg(prop, translator) }
        kwargs << "**#{rest_snake}" if rest_snake

        body = ["    super()"]
        body.concat(props.map do |prop|
          snake = AST::Inflector.underscore(prop.name)
          "    @#{snake} = #{snake}"
        end)
        body << "    @#{rest_snake} = #{rest_snake}" if rest_snake

        "  def initialize(#{kwargs.join(", ")})\n#{body.join("\n")}\n  end"
      end

      def initializable_props(component)
        component.props.reject { |prop| prop.name == DEFAULT_SLOT_NAME }
      end

      def ruby_kwarg(prop, translator)
        snake_name = AST::Inflector.underscore(prop.name)
        default = ruby_default_for(prop, translator)
        "#{snake_name}: #{default}"
      end

      def ruby_default_for(prop, translator)
        return "nil" if prop.default.nil?

        case prop.default
        when IR::Interpolation
          translated = translator.translate(prop.default.expression)
          translated ? translated.ruby : "nil"
        when IR::ObjectLiteral, IR::ArrayLiteral, IR::Lambda
          # Inline values: route through the recursive renderer with
          # `force_inline: true`. A wrapped multi-line default inside the
          # `initialize(...)` parameter list would put the `{` at one
          # column and the children at the indent-aligned column —
          # legal Ruby but trips Layout/FirstHashElementIndentation. Empty
          # todos array — TODO markers wouldn't survive a parameter list.
          render_inline_value(prop.default, translator, todos: [], attr_name: prop.name, force_inline: true)
        else
          "nil"
        end
      end

      def render_view_template(component, translator)
        body = render_template_body(component, translator)
        prefix = render_template_prefix(component)
        body_with_prefix = prefix.empty? ? body : "#{prefix}#{body}"
        "  def view_template\n#{body_with_prefix}\n  end"
      end

      def render_template_prefix(component)
        lines = []
        lines.concat(render_react_hooks_todo(component.react_hooks))
        lines.concat(render_local_bindings_todo(component.local_bindings))
        return "" if lines.empty?

        "#{lines.map { |l| "    #{l}" }.join("\n")}\n"
      end

      def render_react_hooks_todo(hooks)
        return [] if hooks.empty?

        # Preserve the source order of the first occurrence per library so
        # the React block (typical) lands before Apollo/Next.js blocks when
        # all three are present. group_by preserves first-seen order.
        hooks.group_by(&:library).flat_map { |library, calls| hook_todo_block_lines(library, calls) }
      end

      def hook_todo_block_lines(library, calls)
        header_lines = HOOK_TODO_HEADERS.fetch(library, HOOK_TODO_HEADERS[:react])
        lines = header_lines.map { |line| "# #{line}" }
        calls.each do |call|
          lines << "#   operation: #{call.operation}" if call.operation
          lines.concat(comment_lines(call.source))
        end
        lines
      end

      def render_local_bindings_todo(bindings)
        return [] if bindings.empty?

        unique_sources = bindings.map(&:source).uniq
        ["# TODO: translate JS to Ruby — original:"] + unique_sources.flat_map { |src| comment_lines(src) }
      end

      # Prefix every line of `source` with `#   ` so multi-line JS bodies
      # remain inside a Ruby comment block (single `#` on the first line
      # would leave subsequent lines as bare Ruby and break parsing).
      def comment_lines(source)
        source.split("\n").map { |line| "#   #{line}" }
      end

      def render_template_body(component, translator)
        root = component.body
        root = decorate_with_stimulus_controller(root) if component.stimulus_methods.any? && root.is_a?(IR::Element)
        render_ir_node(root, translator, indent: 4)
      end

      def decorate_with_stimulus_controller(element)
        attr = IR::Attribute.new(name: "data-controller", value: @stimulus_identifier)
        IR::Element.new(tag: element.tag, attributes: [attr] + element.attributes, children: element.children)
      end

      def render_ir_node(node, translator, indent:)
        case node
        when IR::Element then render_element(node, translator, indent: indent)
        when IR::ComponentInvocation then render_component_invocation(node, translator, indent: indent)
        when IR::Fragment then render_fragment(node, translator, indent: indent)
        when IR::Conditional then render_conditional(node, translator, indent: indent)
        when IR::Loop then render_loop(node, translator, indent: indent)
        when IR::RenderProp then render_orphan_render_prop(node, translator, indent: indent)
        when IR::LocalRenderCall then render_local_render_call(node, translator, indent: indent)
        when IR::Slot then render_slot(node, indent: indent)
        when IR::Text then render_text(node, indent: indent)
        when IR::Interpolation then render_interpolation(node, translator, indent: indent)
        when IR::Comment then render_comment(node, indent: indent)
        end
      end

      # Emit a call to a previously-extracted RenderMethod. The method body
      # uses `tag.*`/`render` helpers (Phlex executes inside the view), so
      # invoking it inline produces output at the right place in the
      # template. Arg expressions are translated; any that fail translation
      # fall back to verbatim source.
      def render_local_render_call(call, translator, indent:)
        if call.args.empty?
          "#{spaces(indent)}#{call.method_name}"
        else
          arg_sources = call.args.map do |arg|
            translated = translator.translate(arg.expression)
            translated ? translated.ruby : arg.expression
          end
          "#{spaces(indent)}#{call.method_name}(#{arg_sources.join(", ")})"
        end
      end

      # An orphan RenderProp (i.e. one that didn't get consumed as a block
      # by a parent ComponentInvocation). Emit the body inline within the
      # appropriate translator scope; the param names are pushed but no
      # block syntax is generated.
      def render_orphan_render_prop(render_prop, translator, indent:)
        translator.with_locals(render_prop.params) do
          render_ir_node(render_prop.body, translator, indent: indent)
        end
      end

      def render_element(element, translator, indent:)
        todos = []
        attrs_source = format_attributes(element.attributes, translator, context: :html, todos: todos, indent: indent)
        method_call = "#{element.tag}#{attrs_source}"

        body = if VOID_ELEMENTS.include?(element.tag) || element.children.empty?
                 "#{spaces(indent)}#{method_call}"
               else
                 inner = element.children.map { |c| render_ir_node(c, translator, indent: indent + 2) }.join("\n")
                 "#{spaces(indent)}#{method_call} do\n#{inner}\n#{spaces(indent)}end"
               end

        prepend_attribute_todos(todos, indent, body)
      end

      def render_component_invocation(invocation, translator, indent:)
        todos = []
        kwargs = component_invocation_kwargs(invocation.props, translator, todos: todos, indent: indent)
        class_ref = component_class_reference(invocation.name)
        new_call = kwargs.empty? ? "#{class_ref}.new" : "#{class_ref}.new(#{kwargs})"

        render_prop = invocation.children.find { |c| c.is_a?(IR::RenderProp) }
        body = if render_prop
                 render_with_render_prop(new_call, render_prop, translator, indent)
               elsif invocation.children.empty?
                 "#{spaces(indent)}render #{new_call}"
               else
                 inner = invocation.children.map { |c| render_ir_node(c, translator, indent: indent + 2) }.join("\n")
                 "#{spaces(indent)}render #{new_call} do\n#{inner}\n#{spaces(indent)}end"
               end

        prepend_attribute_todos(todos, indent, body)
      end

      # Emit a render-prop child as a Ruby block on the parent `render` call.
      # `<Form.List>{(fields) => <p/>}</Form.List>` →
      # `render Form::List.new do |fields|\n  p\nend`. Param names are
      # snake_cased and pushed into the translator scope so identifier
      # references inside the body resolve to the block locals.
      def render_with_render_prop(new_call, render_prop, translator, indent)
        snake_params = render_prop.params.map { |p| AST::Inflector.underscore(p) }
        param_str = snake_params.empty? ? "" : " |#{snake_params.join(", ")}|"
        inner = translator.with_locals(render_prop.params) do
          render_ir_node(render_prop.body, translator, indent: indent + 2)
        end
        "#{spaces(indent)}render #{new_call} do#{param_str}\n#{inner}\n#{spaces(indent)}end"
      end

      def prepend_attribute_todos(todos, indent, body)
        return body if todos.empty?

        prefix = todos.map { |t| "#{spaces(indent)}# TODO: #{t}" }.join("\n")
        "#{prefix}\n#{body}"
      end

      # JSX `<Foo>` → `Foo` (default), `FooComponent` (suffix), or just
      # `Foo` again under namespace (Ruby's constant lookup finds the
      # peer class). JSX `<Foo.Bar>` → `Foo::Bar` (plus suffix when set).
      # `<HomePage>` keeps the `Page` suffix without doubling (no
      # `HomePageComponent`) — see effective_suffix_for. The path-based
      # page detection doesn't apply here: an invocation only carries
      # the JSX tag name, not the target file's path.
      def component_class_reference(jsx_tag)
        segments = jsx_tag.split(".")
        suffix = effective_suffix_for(segments.last)
        segments[-1] = "#{segments.last}#{suffix}" if suffix
        segments.join("::")
      end

      def render_fragment(fragment, translator, indent:)
        fragment.children.map { |child| render_ir_node(child, translator, indent: indent) }.join("\n")
      end

      def render_conditional(conditional, translator, indent:)
        if guard_ladder?(conditional, translator)
          return render_guard_ladder_collapse(conditional, translator, indent: indent)
        end

        lines = []
        emit_conditional_branches(conditional, translator, indent, lines, leading_keyword: "if")
        lines << "#{spaces(indent)}end"
        lines.join("\n")
      end

      # A guard ladder is a chain of `if/elsif` branches whose tests are all
      # untranslatable AND whose consequents are all "render nothing" (the
      # lowered form of `return null` in a guard), terminating in a real
      # else branch. Emitted naively as `if false / elsif false / .../ else
      # <main>`, the else *always* fires — silently inverting the source
      # semantic ("render nothing when any guard hits") into "render main
      # unconditionally." Collapse to a single TODO block + just the else
      # so the reviewer sees what guards used to gate the render, and the
      # main render is at least visible without the misleading `if false`s.
      def guard_ladder?(conditional, translator)
        branches, else_branch = walk_conditional_chain(conditional)
        return false unless else_branch
        return false if branches.empty?

        branches.all? do |b|
          test_translates_to_untranslatable?(b[:test], translator) && empty_consequent?(b[:consequent])
        end
      end

      def render_guard_ladder_collapse(conditional, translator, indent:)
        branches, else_branch = walk_conditional_chain(conditional)
        lines = ["#{spaces(indent)}# TODO: #{branches.length} render guard(s) couldn't translate; wire up Rails-side:"]
        branches.each do |b|
          compact = b[:test].tr("\n", " ").squeeze(" ")
          lines << "#{spaces(indent)}#   #{compact}"
        end
        lines << render_ir_node(else_branch, translator, indent: indent)
        lines.join("\n")
      end

      def walk_conditional_chain(conditional)
        branches = []
        node = conditional
        while node.is_a?(IR::Conditional)
          branches << { test: node.test.expression, consequent: node.consequent }
          node = node.alternate
        end
        [branches, node]
      end

      def test_translates_to_untranslatable?(expression, translator)
        translated = translator.translate(expression)
        translated.nil? || translated.ruby == "nil"
      end

      # An empty consequent is what `return null` (the JS guard idiom) lowers
      # to. Detected as either a literal empty Text node or a Fragment whose
      # children are all empty.
      def empty_consequent?(node)
        case node
        when IR::Text then node.value.to_s.empty?
        when IR::Fragment then node.children.all? { |c| empty_consequent?(c) }
        else false
        end
      end

      # Walk a Conditional and its `alternate` chain, emitting `if` for the
      # first test, `elsif` for each alternate that is itself a Conditional,
      # and a final `else` for a non-Conditional alternate. Flattens the
      # `if X / else / if Y / end / end` shape that JS `else if` chains
      # produce into idiomatic Ruby `if X / elsif Y / else / end`. Without
      # this, deeply nested conditional chains explode the file's
      # indentation and trip Style/IfInsideElse + Metrics/BlockNesting.
      def emit_conditional_branches(conditional, translator, indent, lines, leading_keyword:)
        test_ruby, todo = safe_test_expression(conditional.test.expression, translator, fallback: "false")
        lines << "#{spaces(indent)}# TODO: translate condition: #{todo}" if todo
        lines << "#{spaces(indent)}#{leading_keyword} #{test_ruby}"
        lines << render_ir_node(conditional.consequent, translator, indent: indent + 2)

        alt = conditional.alternate
        return unless alt

        if alt.is_a?(IR::Conditional)
          emit_conditional_branches(alt, translator, indent, lines, leading_keyword: "elsif")
        else
          lines << "#{spaces(indent)}else"
          lines << render_ir_node(alt, translator, indent: indent + 2)
        end
      end

      def render_loop(loop_node, translator, indent:)
        iterable_ruby, todo = render_loop_iterable(loop_node.iterable, translator)
        js_bindings = [loop_node.item_binding, loop_node.index_binding].compact
        ruby_bindings = js_bindings.map { |name| AST::Inflector.underscore(name) }
        binding_str = ruby_bindings.size == 1 ? "|#{ruby_bindings.first}|" : "|#{ruby_bindings.join(", ")}|"

        body = translator.with_locals(js_bindings) do
          render_ir_node(loop_node.body, translator, indent: indent + 2)
        end

        lines = []
        lines << "#{spaces(indent)}# TODO: translate iterable: #{todo}" if todo
        lines << "#{spaces(indent)}#{iterable_ruby}.each do #{binding_str}"
        lines << body
        lines << "#{spaces(indent)}end"
        lines.join("\n")
      end

      # Translate the iterable side of a `.each` call. Handles both the
      # traditional Interpolation form and the new ArrayLiteral form
      # (literal array `.map(...)`) introduced by Gap H. Returns
      # [ruby_source, todo_text]; todo_text is nil when translation succeeded.
      def render_loop_iterable(iterable, translator)
        case iterable
        when IR::ArrayLiteral
          [render_array_literal_value(iterable, translator, todos: []), nil]
        when IR::Interpolation
          safe_test_expression(iterable.expression, translator, fallback: "[]")
        else
          ["[]", iterable.inspect]
        end
      end

      # Translate an expression intended to drive an `if` or `.each` call.
      # Returns `[ruby_source, todo_text]`. When the translator can parse
      # the expression, `todo_text` is nil. When it can't, the caller's
      # `fallback` (e.g. `"false"` for conditions, `"[]"` for iterables)
      # is returned along with the original expression so a TODO comment
      # can be emitted above the call. Without this, JS operators like
      # `!==`, `===`, optional chaining, and `in` would leak into the
      # emitted Ruby and produce SyntaxError on load.
      #
      # A translated value of `"nil"` is treated as untranslatable: the
      # translator returns `"nil"` for known-local bindings (so the file
      # loads as a leaf reference), but driving an `if` with `nil` silently
      # disables the whole branch. Fall through to the TODO path instead so
      # the human reviewer sees what needs filling in.
      def safe_test_expression(expression, translator, fallback:)
        translated = translator.translate(expression)
        return [translated.ruby, nil] if translated && translated.ruby != "nil"

        compact = expression.tr("\n", " ").squeeze(" ")
        [fallback, compact]
      end

      def render_slot(slot, indent:)
        if slot.name == DEFAULT_SLOT_NAME
          "#{spaces(indent)}yield"
        else
          "#{spaces(indent)}# TODO: named slot #{slot.name.inspect}"
        end
      end

      def render_text(text, indent:)
        "#{spaces(indent)}plain #{AST::Inflector.ruby_string_literal(text.value)}"
      end

      def render_interpolation(interpolation, translator, indent:)
        translated = translator.translate(interpolation.expression)
        return render_untranslated_interpolation(interpolation.expression, indent) unless translated

        unresolved = translated.unresolved_identifiers
        if unresolved.empty?
          "#{spaces(indent)}plain #{translated.ruby}#{react_node_hint(translated.ruby)}"
        else
          names = unresolved.map(&:inspect).join(", ")
          "#{spaces(indent)}# TODO: unresolved identifier #{names}\n" \
            "#{spaces(indent)}plain #{translated.ruby}"
        end
      end

      # Gap G: when the translated value is a bare `@ivar` reference, the
      # prop may be a ReactNode (children-typed prop) rather than a plain
      # string. `plain` HTML-escapes its argument; `raw` doesn't. We can't
      # tell at translation time which is intended, so default to `plain`
      # (safe for string props) and emit a comment hint pointing at `raw`.
      def react_node_hint(ruby)
        return "" unless ruby.is_a?(String)
        return "" unless ruby.match?(/\A@[a-z_][a-z0-9_]*\z/)

        " # NOTE: use `raw` instead of `plain` if this is a ReactNode-typed prop"
      end

      # The original JS expression couldn't be translated to Ruby. We can't
      # emit `plain <verbatim-JS>` because raw JS (TypeScript casts, JSX
      # method chains, ternary spreads, etc.) usually isn't valid Ruby.
      # Instead, emit two safe lines: a `# TODO:` comment naming the
      # expression, then a string-literal placeholder so the template still
      # renders something visible at runtime.
      def render_untranslated_interpolation(expression, indent)
        compact = expression.tr("\n", " ").squeeze(" ")
        placeholder = AST::Inflector.ruby_string_literal("[untranslated: #{compact}]")
        "#{spaces(indent)}# TODO: translate #{compact.inspect}\n" \
          "#{spaces(indent)}plain #{placeholder}"
      end

      def render_comment(comment, indent:)
        # Multi-line JSX comments need every line prefixed with `# ` — a
        # bare first-line `#` would leave subsequent lines as Ruby code.
        comment.text.split("\n").map { |line| "#{spaces(indent)}# #{line}" }.join("\n")
      end

      # Build the Ruby attribute list — `(id: @id, class: @class, ...)`  —
      # to splice immediately after the tag method name. Returns "" when
      # there are no attributes (so the caller emits a bare `h1` instead
      # of `h1()`). The `context:` param selects naming convention:
      #   - :html       (HTML element attrs — preserve camelCase for SVG)
      #   - :component  (Ruby method args — snake_case via Inflector.underscore)
      def format_attributes(attributes, translator, context: :html, todos: [], indent: 0)
        events, others = attributes.partition { |a| a.is_a?(IR::EventBinding) || a.is_a?(IR::StimulusBinding) }
        spreads, plain_attrs = others.partition { |a| a.is_a?(IR::SpreadAttribute) }

        parts = { sym: [], str: [] }
        plain_attrs.each do |a|
          append_attribute_part(a, translator, parts, context: context, todos: todos, indent: indent)
        end
        parts[:sym] << data_action_entry(events, translator) if events.any?

        joined = build_attribute_list(parts, spreads, translator)
        joined.empty? ? "" : "(#{joined})"
      end

      def append_attribute_part(attribute, translator, parts, context:, todos:, indent: 0)
        part = phlex_attribute_part(attribute, translator, context: context, todos: todos, indent: indent)
        return unless part

        (part[:string_key] ? parts[:str] : parts[:sym]) << part[:source]
      end

      def build_attribute_list(parts, spreads, translator)
        pieces = parts[:sym].dup
        pieces << "**{ #{parts[:str].join(", ")} }" if parts[:str].any?
        pieces.concat(spreads.map { |s| "**#{render_spread(s.expression, translator)}" })
        pieces.join(", ")
      end

      # Emit one attribute as either a {string_key: false, source: "id: @x"}
      # (Ruby-kwarg-safe name) or {string_key: true, source: '"xml:lang" => @x'}
      # (rare; non-identifier name — goes into a **{ ... } splat). Returns
      # nil to signal "drop this attribute entirely" — used when every style
      # declaration dropped (would emit `style: ''`) or every plain-attribute
      # value bailed (would emit `attr: nil`); the TODO comment above the
      # element already describes what was lost.
      def phlex_attribute_part(attribute, translator, context:, todos:, indent: 0)
        case attribute
        when IR::StyleBinding then class_attribute_part(attribute.expression, translator)
        when IR::ClassList then { string_key: false, source: "class: #{class_list_to_ruby_string(attribute, translator)}" }
        when IR::Style then style_attribute_part(attribute, translator, todos: todos)
        when IR::Attribute
          plain_attribute_part(attribute, translator, context: context, todos: todos, indent: indent)
        end
      end

      # Skip the `style:` kwarg entirely when every declaration failed to
      # translate — `style: ''` is invalid HTML output and pure noise; the
      # per-declaration TODO comments above the element preserve what was
      # there.
      def style_attribute_part(style, translator, todos:)
        ruby = style_to_ruby_string(style, translator, todos: todos)
        return nil if empty_style_ruby?(ruby)

        { string_key: false, source: "style: #{ruby}" }
      end

      def empty_style_ruby?(ruby)
        ["''", '""'].include?(ruby)
      end

      # A "dropped" attribute is one where translation failed AND the
      # fallback was the literal `nil` string. We detect this by watching
      # whether a TODO was appended during the value computation: a real
      # `attr={null}` in the source produces `nil` *without* a TODO and
      # should still emit (preserves intent); a failed translation
      # produces `nil` *with* a TODO and we drop the kwarg to keep output
      # clean — the TODO above the element already describes the loss.
      def dropped_value?(value_ruby, todos_before, todos_after)
        value_ruby == "nil" && todos_after.length > todos_before
      end

      def class_attribute_part(expression, translator)
        translated = translator.translate(expression)
        ruby = translated ? translated.ruby : expression.inspect
        { string_key: false, source: "class: #{ruby}" }
      end

      # Map a JSX attribute name to its Ruby kwarg form. For HTML element
      # attrs (`context: :html`), only hyphens convert to underscores —
      # camelCase (`viewBox`, `preserveAspectRatio`) preserves verbatim
      # so SVG attributes render correctly through Phlex. For component
      # invocations (`context: :component`), full Inflector.underscore
      # converts both hyphens AND camelCase, since Ruby method args
      # follow snake_case convention (`defaultValue` → `default_value`).
      # Names that aren't valid Ruby identifiers after conversion (rare:
      # `xml:lang` and friends) fall back to a quoted string key.
      def plain_attribute_part(attribute, translator, context:, todos:, indent: 0)
        todos_before = todos.length
        value_ruby = attribute_value_to_ruby(attribute.name, attribute.value, translator, todos: todos, indent: indent)
        return nil if dropped_value?(value_ruby, todos_before, todos)

        ruby_name = case context
                    when :component then AST::Inflector.underscore(attribute.name)
                    else attribute.name.tr("-", "_")
                    end
        if ruby_name.match?(VALID_IDENTIFIER)
          { string_key: false, source: "#{ruby_name}: #{value_ruby}" }
        else
          { string_key: true, source: "#{AST::Inflector.ruby_string_literal(attribute.name)} => #{value_ruby}" }
        end
      end

      def attribute_value_to_ruby(name, value, translator, todos:, indent: 0)
        case value
        when true then "true"
        when String then AST::Inflector.ruby_string_literal(value)
        when IR::Interpolation then interpolated_attribute_value(name, value, translator, todos: todos)
        when IR::ObjectLiteral then render_object_literal_value(value, translator, todos: todos, indent: indent)
        when IR::ArrayLiteral then render_array_literal_value(value, translator, todos: todos, indent: indent)
        when IR::Lambda then render_lambda_method_reference(value, translator, attr_name: name)
        when IR::EventHandler then render_event_handler_method_reference(value, attr_name: name)
        when IR::ComponentInvocation
          component_invocation_value(value, translator, todos: todos, attr_name: name)
        when IR::Element, IR::Fragment
          # An HTML tag (`title={<span>x</span>}`) or a multi-element
          # Fragment as an attribute value needs a Phlex execution context
          # the receiver might not provide. Drop with a TODO rather than
          # emit a broken kwarg or a speculative method reference.
          drop_jsx_value_with_todo(name, value, todos: todos)
        end
      end

      # Render an ObjectLiteral as a Ruby hash literal. Identifier-keyed
      # entries become Ruby kwargs (snake_cased to match Ruby convention);
      # non-identifier keys (numeric, hyphenated) fall back to string keys.
      # When the single-line rendering exceeds LITERAL_INLINE_BUDGET, or
      # when any rendered child value spans multiple lines, the layout
      # switches to one entry per line, indented two spaces past `indent`.
      def render_object_literal_value(object_literal, translator, todos:, indent: 0, force_inline: false)
        child_indent = indent + 2
        parts = object_literal.properties.map do |(key, value)|
          render_object_property(key, value, translator, todos: todos, indent: child_indent, force_inline: force_inline)
        end
        wrap_literal_parts(parts, open: "{", close: "}", indent: indent, inline_sep: ", ", inline_pad: " ",
                                  force_inline: force_inline)
      end

      def render_object_property(key, value, translator, todos:, indent: 0, force_inline: false)
        value_ruby = render_inline_value(value, translator, todos: todos, attr_name: key, indent: indent,
                                                            force_inline: force_inline)
        snake = AST::Inflector.underscore(key)
        if snake.match?(VALID_IDENTIFIER)
          "#{snake}: #{value_ruby}"
        else
          "#{AST::Inflector.ruby_string_literal(key)} => #{value_ruby}"
        end
      end

      def render_array_literal_value(array_literal, translator, todos:, indent: 0, force_inline: false)
        child_indent = indent + 2
        parts = array_literal.elements.map do |el|
          if el.nil?
            "nil"
          else
            render_inline_value(el, translator, todos: todos, attr_name: nil, indent: child_indent,
                                                force_inline: force_inline)
          end
        end
        wrap_literal_parts(parts, open: "[", close: "]", indent: indent, inline_sep: ", ", inline_pad: "",
                                  force_inline: force_inline)
      end

      # Pick single-line vs multi-line layout for a rendered literal.
      # Multi-line is forced when any rendered part already contains a
      # newline (a nested literal that wrapped); otherwise we wrap only
      # when the single-line form exceeds LITERAL_INLINE_BUDGET.
      def wrap_literal_parts(parts, **opts)
        open = opts[:open]
        close = opts[:close]
        return "#{open}#{close}" if parts.empty?

        inline = "#{open}#{opts[:inline_pad]}#{parts.join(opts[:inline_sep])}#{opts[:inline_pad]}#{close}"
        any_multiline = parts.any? { |p| p.include?("\n") }
        return inline if opts[:force_inline]
        return inline if !any_multiline && inline.length <= LITERAL_INLINE_BUDGET

        child_pad = " " * (opts[:indent] + 2)
        close_pad = " " * opts[:indent]
        "#{open}\n#{child_pad}#{parts.join(",\n#{child_pad}")}\n#{close_pad}#{close}"
      end

      # An inline value can appear as a kwarg value, an array element, or a
      # hash property value. Recursive shapes route back through the new IR
      # types; primitives fall through the same paths as attribute_value_to_ruby.
      def render_inline_value(value, translator, todos:, attr_name:, indent: 0, force_inline: false)
        case value
        when IR::ObjectLiteral
          render_object_literal_value(value, translator, todos: todos, indent: indent, force_inline: force_inline)
        when IR::ArrayLiteral
          render_array_literal_value(value, translator, todos: todos, indent: indent, force_inline: force_inline)
        when IR::Lambda then render_lambda_method_reference(value, translator, attr_name: attr_name)
        when IR::EventHandler then render_event_handler_method_reference(value, attr_name: attr_name)
        when IR::Interpolation then interpolated_attribute_value(attr_name || "<element>", value, translator,
                                                                 todos: todos)
        when IR::ComponentInvocation
          component_invocation_value(value, translator, todos: todos, attr_name: attr_name)
        when IR::Element, IR::Fragment
          drop_jsx_value_with_todo(attr_name, value, todos: todos)
        when String then AST::Inflector.ruby_string_literal(value)
        when true then "true"
        else
          "nil"
        end
      end

      # An IR::Lambda lives inside an object/array literal as a value. We
      # extract it to a method on the class (so it has access to the
      # Phlex tag.* helpers) and reference it via `method(:name)` in the
      # value position. Method names are deterministic so re-runs produce
      # stable output: `<attr-name>_renderer<N>` where N is a per-attr index.
      def render_lambda_method_reference(lambda, translator, attr_name:)
        @lambda_methods ||= []
        base = lambda_method_base(attr_name)
        @lambda_methods << { base: base, lambda: lambda, translator: translator }
        # Index is the position within `@lambda_methods` so re-renders are
        # deterministic in the order encountered.
        method_name = unique_lambda_method_name(base)
        @lambda_methods.last[:method_name] = method_name
        "method(:#{method_name})"
      end

      def lambda_method_base(attr_name)
        return "render_lambda" if attr_name.nil? || attr_name.empty?

        "render_#{AST::Inflector.underscore(attr_name)}"
      end

      def unique_lambda_method_name(base)
        @lambda_method_counts ||= {}
        @lambda_method_counts[base] ||= 0
        @lambda_method_counts[base] += 1
        @lambda_method_counts[base] == 1 ? base : "#{base}#{@lambda_method_counts[base]}"
      end

      # Inline arrow event handler on a PascalCase tag — `onClick={() =>
      # doX()}` on `<Button>`. Extract to a stub method on the class and
      # reference via `method(:handle_click)` at the kwarg position so the
      # receiving component has a callable. The body translation is left
      # to the human reviewer (the JS source is preserved as a TODO
      # comment inside the method), but the structural wiring is intact.
      def render_event_handler_method_reference(handler, attr_name:)
        @event_handler_methods ||= []
        base = event_handler_method_base(attr_name)
        method_name = unique_lambda_method_name(base)
        @event_handler_methods << { handler: handler, method_name: method_name, attr_name: attr_name }
        "method(:#{method_name})"
      end

      # Map a JSX attribute name to an idiomatic Ruby handler-method name.
      # `onClick` → `handle_click` (mirrors React's `handleClick` convention,
      # snake_cased). Non-event attrs (rare — a callback prop with no `on`
      # prefix) fall back to `<attr>_handler`.
      def event_handler_method_base(attr_name)
        return "anonymous_handler" if attr_name.nil? || attr_name.empty?

        snake = AST::Inflector.underscore(attr_name)
        snake.start_with?("on_") ? "handle_#{snake.delete_prefix("on_")}" : "#{snake}_handler"
      end

      # Attribute-position interpolation. Three failure modes:
      #   1. Translator returns non-nil, no unresolved identifiers — emit
      #      the Ruby reference directly. Common case.
      #   2. Translator returns non-nil but with unresolved identifiers
      #      starting with uppercase (PascalCase / SCREAMING_SNAKE_CASE —
      #      almost always imported constants or enums) — emitting bare
      #      `default_page_size` from `DEFAULT_PAGE_SIZE` produces a
      #      runtime NameError with no marker. Drop the value to `nil`
      #      and surface a TODO with the verbatim source. Lowercase
      #      unresolved identifiers may be Rails helpers (`current_user`)
      #      and are passed through as before.
      #   3. Translator returns nil — the original JS expression couldn't
      #      be parsed at all (e.g. `<LeftOutlined .../>`, array literals,
      #      template literals with method calls). Same TODO + nil path.
      def interpolated_attribute_value(name, value, translator, todos:)
        translated = translator.translate(value.expression)
        return translated.ruby if translated && !uppercase_unresolved?(translated.unresolved_identifiers)

        compact = value.expression.tr("\n", " ").squeeze(" ")
        todos << "attribute #{name.inspect} dropped — couldn't translate: #{compact}"
        "nil"
      end

      def uppercase_unresolved?(unresolved_identifiers)
        unresolved_identifiers.any? { |name| name[0] == name[0].upcase }
      end

      # JSX appearing as an attribute value — typically `icon={<Foo/>}` or
      # `fallback={<Loading/>}` on antd/MUI components. Emitted as a
      # component-instance value: `icon: FooComponent.new`. The receiving
      # Phlex component can render it directly via `render @icon`. Closes
      # the largest single category of attribute-value drops we were
      # silently emitting as `attr: nil` + TODO.
      #
      # Three child-handling tiers:
      #   1. No children — `ClassRef.new(kwargs)` on one line.
      #   2. Children whose rendered Phlex body fits a single line — emit
      #      as a block: `ClassRef.new(kwargs) { plain "x" }`. The block
      #      runs in the child component's render context, so HTML helpers
      #      resolve correctly.
      #   3. Children that need multiple lines, or any IR::Element /
      #      IR::Fragment we can't represent inline — fall back to the
      #      existing TODO drop. Out of MVP scope; expand later if the
      #      stress numbers warrant it.
      def component_invocation_value(invocation, translator, todos:, attr_name:)
        return drop_attribute_with_todo(attr_name, invocation, todos: todos) if invocation_has_render_prop?(invocation)

        kwargs = component_invocation_kwargs(invocation.props, translator, todos: todos, indent: 0)
        class_ref = component_class_reference(invocation.name)
        new_call = kwargs.empty? ? "#{class_ref}.new" : "#{class_ref}.new(#{kwargs})"

        return new_call if invocation.children.empty?

        block_body = render_inline_children(invocation.children, translator)
        return drop_attribute_with_todo(attr_name, invocation, todos: todos) unless block_body

        "#{new_call} { #{block_body} }"
      end

      def invocation_has_render_prop?(invocation)
        invocation.children.any?(IR::RenderProp)
      end

      # Render children to a single-line Phlex block body. Returns nil when
      # any child needs multiple lines or isn't representable inline — the
      # caller falls back to the TODO drop.
      def render_inline_children(children, translator)
        rendered = children.map { |c| render_ir_node(c, translator, indent: 0) }
        return nil if rendered.any? { |line| line.include?("\n") }

        joined = rendered.join("; ")
        joined.length <= LITERAL_INLINE_BUDGET ? joined : nil
      end

      def drop_attribute_with_todo(attr_name, invocation, todos:)
        label = attr_name || "<element>"
        compact = invocation_source_summary(invocation)
        todos << "attribute #{label.inspect} dropped — couldn't inline JSX value: #{compact}"
        "nil"
      end

      def invocation_source_summary(invocation)
        tag = invocation.name
        suffix = invocation.children.empty? ? "/" : "...>"
        "<#{tag}#{suffix}"
      end

      def drop_jsx_value_with_todo(attr_name, value, todos:)
        label = attr_name || "<element>"
        summary = case value
                  when IR::Element then "<#{value.tag}...>"
                  when IR::Fragment then "<>...</>"
                  else "<JSX>"
                  end
        todos << "attribute #{label.inspect} dropped — couldn't inline JSX value: #{summary}"
        "nil"
      end

      def component_invocation_kwargs(props, translator, todos: [], indent: 0)
        events, others = props.partition { |a| a.is_a?(IR::EventBinding) || a.is_a?(IR::StimulusBinding) }
        spreads, plain_attrs = others.partition { |a| a.is_a?(IR::SpreadAttribute) }

        parts = { sym: [], str: [] }
        plain_attrs.each do |a|
          append_attribute_part(a, translator, parts, context: :component, todos: todos, indent: indent)
        end
        parts[:sym] << data_action_entry(events, translator) if events.any?

        build_attribute_list(parts, spreads, translator)
      end

      def class_list_to_ruby_string(class_list, translator)
        parts = class_list.segments.map { |seg| class_segment_to_ruby(seg, translator) }
        wrap_concatenated_string(parts.join(" "))
      end

      def class_segment_to_ruby(segment, translator)
        case segment
        when String then segment
        when IR::Interpolation
          translated = translator.translate(segment.expression)
          "\#{#{translated&.ruby || segment.expression}}"
        when IR::ConditionalSegment
          cond_translated = translator.translate(segment.condition.expression)
          cond_ruby = cond_translated&.ruby || segment.condition.expression
          %(\#{#{cond_ruby} ? #{AST::Inflector.ruby_string_literal(segment.class_name)} : ''})
        end
      end

      def style_to_ruby_string(style, translator, todos: [])
        parts = style.declarations.filter_map { |decl| style_declaration_to_ruby(decl, translator, todos: todos) }
        wrap_concatenated_string(parts.join(" "))
      end

      # Wrap a built-up Ruby string body in single quotes when it contains
      # no interpolation (`\#{...}`) and no escaping pitfalls; otherwise
      # use double quotes so the interpolation is honored. Keeps class /
      # style attribute output passing Style/StringLiterals when no
      # dynamic segments are present (the common case for hardcoded
      # `style="margin-bottom: 16px"`).
      def wrap_concatenated_string(body)
        return %("#{body}") if body.include?("\#{") || body.include?("'") || body.include?("\\")

        "'#{body}'"
      end

      def style_declaration_to_ruby(decl, translator, todos: [])
        case decl.value
        when String
          "#{decl.property}: #{decl.value};"
        when IR::Interpolation
          translated = translator.translate(decl.value.expression)
          # Translation failed (e.g., interpolation rooted at an
          # unresolvable local). Emitting the verbatim JS source inside
          # `\#{}` would render valid Ruby that NameErrors at runtime.
          # Drop the declaration and surface a TODO above the element so
          # the reviewer sees what was lost.
          if translated.nil?
            todos << "style declaration #{decl.property.inspect} dropped — " \
                     "couldn't translate: #{decl.value.expression}"
            nil
          else
            "#{decl.property}: \#{#{translated.ruby}};"
          end
        end
      end

      # Wrap the spread expression in `(… || {})` so a nil-valued prop
      # default doesn't raise at render time. `<div {...maybeNil}>` →
      # `**(@maybe_nil || {})`. Cheap to emit unconditionally; the
      # `|| {}` shortcuts on non-nil values.
      def render_spread(expression, translator)
        translated = translator.translate(expression)
        ruby = translated ? translated.ruby : expression
        "(#{ruby} || {})"
      end

      # Build the `data_action: "..."` kwarg. Phlex auto-hyphenates the
      # `data_action` symbol key to `data-action` in the rendered HTML.
      def data_action_entry(events, translator)
        descriptors = events.map { |event| event_descriptor(event, translator) }
        joined = if descriptors.size == 1
                   render_single_event_descriptor(descriptors.first)
                 else
                   %("#{descriptors.map { |d| descriptor_in_string(d) }.join(" ")}")
                 end
        "data_action: #{joined}"
      end

      def event_descriptor(event, translator)
        case event
        when IR::EventBinding
          translated = translator.translate(event.handler.expression)
          EventDescriptor.new(:ruby, translated ? translated.ruby : event.handler.expression.inspect)
        when IR::StimulusBinding
          EventDescriptor.new(:literal, "#{event.event}->#{@stimulus_identifier}##{event.method_name}")
        end
      end

      def render_single_event_descriptor(descriptor)
        descriptor.kind == :literal ? AST::Inflector.ruby_string_literal(descriptor.body) : descriptor.body
      end

      def descriptor_in_string(descriptor)
        descriptor.kind == :literal ? descriptor.body : "\#{#{descriptor.body}}"
      end

      def render_stimulus_controller_js(component)
        lines = [
          'import { Controller } from "@hotwired/stimulus";',
          "",
          "export default class extends Controller {"
        ]
        component.stimulus_methods.each_with_index do |method, idx|
          lines << "" if idx.positive?
          lines.concat(stimulus_method_lines(method))
        end
        lines << "}"
        "#{lines.join("\n")}\n"
      end

      def stimulus_method_lines(method)
        body_lines = method.body_source.strip.split("\n")
        commented = body_lines.map { |line| "  //   #{line}" }
        header = ["  // TODO: translate from the original JSX handler:"]
        if method.name != method.original_name
          header.unshift("  // NOTE: method renamed from #{method.original_name.inspect} " \
                         "to avoid collision with an earlier handler")
        end
        header + commented + [
          "  #{method.name}(event) {",
          "    // ...",
          "  }"
        ]
      end

      def spaces(count)
        " " * count
      end
    end
  end
end
