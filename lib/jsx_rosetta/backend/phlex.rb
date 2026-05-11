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

      # Structured intermediate for the data-action attribute — mirrors the
      # ViewComponent backend pattern (lib/jsx_rosetta/backend/view_component.rb).
      EventDescriptor = Data.define(:kind, :body)

      def initialize(suffix: nil, namespace: nil)
        super()
        raise ArgumentError, "Phlex backend: pass either suffix: or namespace:, not both" if suffix && namespace

        @suffix = suffix.is_a?(String) ? suffix : (DEFAULT_SUFFIX if suffix == true)
        @namespace = namespace
      end

      def emit(component)
        prop_names = component.props.map(&:name)
        prop_names << component.rest_prop_name if component.rest_prop_name
        translator = ViewComponent::ExpressionTranslator.new(prop_names: prop_names)

        @stimulus_identifier = component.stimulus_methods.any? ? stimulus_identifier(component) : nil

        files = [File.new(path: ruby_path(component), contents: render_ruby_class(component, translator))]
        if component.stimulus_methods.any?
          files << File.new(
            path: stimulus_path(component),
            contents: render_stimulus_controller_js(component)
          )
        end
        files
      end

      private

      # JSX-returning lowercase helpers (e.g. `textRender`, `getNodeIcon`)
      # have lowercase-starting names. Ruby class names must be constants
      # (begin with an uppercase letter), so we capitalize the first
      # letter when forming the class name. Pure-PascalCase names pass
      # through unchanged.
      def class_name(component)
        base = "#{component.name[0].upcase}#{component.name[1..]}"
        @suffix ? "#{base}#{@suffix}" : base
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
        wrap_in_namespace(class_body)
      end

      def wrap_in_namespace(body)
        return "# frozen_string_literal: true\n\n#{body}" unless @namespace

        indented = body.lines.map { |line| line.strip.empty? ? line : "  #{line}" }.join
        "# frozen_string_literal: true\n\nmodule #{@namespace}\n#{indented}end\n"
      end

      def render_class_body(component, translator)
        initializer = render_initializer(component, translator)
        template = render_view_template(component, translator)

        sections = [initializer, template].compact.join("\n\n")
        "class #{class_name(component)} < #{PHLEX_BASE_CLASS}\n#{sections}\nend\n"
      end

      def render_initializer(component, translator)
        props = initializable_props(component)
        rest_name = component.rest_prop_name
        return nil if props.empty? && rest_name.nil?

        kwargs = props.map { |prop| ruby_kwarg(prop, translator) }
        kwargs << "**#{rest_name}" if rest_name

        assignments = props.map do |prop|
          snake = AST::Inflector.underscore(prop.name)
          "    @#{snake} = #{snake}"
        end
        assignments << "    @#{rest_name} = #{rest_name}" if rest_name

        "  def initialize(#{kwargs.join(", ")})\n#{assignments.join("\n")}\n  end"
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

        translated = translator.translate(prop.default.expression)
        translated ? translated.ruby : "nil # TODO: translate #{prop.default.expression.inspect}"
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

        lines = [
          "# TODO: React hooks detected. None translate automatically.",
          "# Hotwire/Stimulus handles behavior; controllers/views handle state;",
          "# turbo-frames handle async loading. Original source:"
        ]
        hooks.each { |hook| lines.concat(comment_lines(hook.source)) }
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
        when IR::Slot then render_slot(node, indent: indent)
        when IR::Text then render_text(node, indent: indent)
        when IR::Interpolation then render_interpolation(node, translator, indent: indent)
        when IR::Comment then render_comment(node, indent: indent)
        end
      end

      def render_element(element, translator, indent:)
        todos = []
        attrs_source = format_attributes(element.attributes, translator, context: :html, todos: todos)
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
        kwargs = component_invocation_kwargs(invocation.props, translator, todos: todos)
        class_ref = component_class_reference(invocation.name)
        new_call = kwargs.empty? ? "#{class_ref}.new" : "#{class_ref}.new(#{kwargs})"

        body = if invocation.children.empty?
                 "#{spaces(indent)}render #{new_call}"
               else
                 inner = invocation.children.map { |c| render_ir_node(c, translator, indent: indent + 2) }.join("\n")
                 "#{spaces(indent)}render #{new_call} do\n#{inner}\n#{spaces(indent)}end"
               end

        prepend_attribute_todos(todos, indent, body)
      end

      def prepend_attribute_todos(todos, indent, body)
        return body if todos.empty?

        prefix = todos.map { |t| "#{spaces(indent)}# TODO: #{t}" }.join("\n")
        "#{prefix}\n#{body}"
      end

      # JSX `<Foo>` → `Foo` (default), `FooComponent` (suffix), or just
      # `Foo` again under namespace (Ruby's constant lookup finds the
      # peer class). JSX `<Foo.Bar>` → `Foo::Bar` (plus suffix when set).
      def component_class_reference(jsx_tag)
        segments = jsx_tag.split(".")
        segments[-1] = "#{segments.last}#{@suffix}" if @suffix
        segments.join("::")
      end

      def render_fragment(fragment, translator, indent:)
        fragment.children.map { |child| render_ir_node(child, translator, indent: indent) }.join("\n")
      end

      def render_conditional(conditional, translator, indent:)
        test_ruby, todo = safe_test_expression(conditional.test.expression, translator, fallback: "false")
        lines = []
        lines << "#{spaces(indent)}# TODO: translate condition: #{todo}" if todo
        lines << "#{spaces(indent)}if #{test_ruby}"
        lines << render_ir_node(conditional.consequent, translator, indent: indent + 2)
        if conditional.alternate
          lines << "#{spaces(indent)}else"
          lines << render_ir_node(conditional.alternate, translator, indent: indent + 2)
        end
        lines << "#{spaces(indent)}end"
        lines.join("\n")
      end

      def render_loop(loop_node, translator, indent:)
        iterable_ruby, todo = safe_test_expression(loop_node.iterable.expression, translator, fallback: "[]")
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

      # Translate an expression intended to drive an `if` or `.each` call.
      # Returns `[ruby_source, todo_text]`. When the translator can parse
      # the expression, `todo_text` is nil. When it can't, the caller's
      # `fallback` (e.g. `"false"` for conditions, `"[]"` for iterables)
      # is returned along with the original expression so a TODO comment
      # can be emitted above the call. Without this, JS operators like
      # `!==`, `===`, optional chaining, and `in` would leak into the
      # emitted Ruby and produce SyntaxError on load.
      def safe_test_expression(expression, translator, fallback:)
        translated = translator.translate(expression)
        return [translated.ruby, nil] if translated

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
        "#{spaces(indent)}plain #{text.value.inspect}"
      end

      def render_interpolation(interpolation, translator, indent:)
        translated = translator.translate(interpolation.expression)
        return render_untranslated_interpolation(interpolation.expression, indent) unless translated

        unresolved = translated.unresolved_identifiers
        if unresolved.empty?
          "#{spaces(indent)}plain #{translated.ruby}"
        else
          names = unresolved.map(&:inspect).join(", ")
          "#{spaces(indent)}# TODO: unresolved identifier #{names}\n" \
            "#{spaces(indent)}plain #{translated.ruby}"
        end
      end

      # The original JS expression couldn't be translated to Ruby. We can't
      # emit `plain <verbatim-JS>` because raw JS (TypeScript casts, JSX
      # method chains, ternary spreads, etc.) usually isn't valid Ruby.
      # Instead, emit two safe lines: a `# TODO:` comment naming the
      # expression, then a string-literal placeholder so the template still
      # renders something visible at runtime.
      def render_untranslated_interpolation(expression, indent)
        compact = expression.tr("\n", " ").squeeze(" ")
        "#{spaces(indent)}# TODO: translate #{compact.inspect}\n" \
          "#{spaces(indent)}plain #{"[untranslated: #{compact}]".inspect}"
      end

      def render_comment(comment, indent:)
        "#{spaces(indent)}# #{comment.text}"
      end

      # Build the Ruby attribute list — `(id: @id, class: @class, ...)`  —
      # to splice immediately after the tag method name. Returns "" when
      # there are no attributes (so the caller emits a bare `h1` instead
      # of `h1()`). The `context:` param selects naming convention:
      #   - :html       (HTML element attrs — preserve camelCase for SVG)
      #   - :component  (Ruby method args — snake_case via Inflector.underscore)
      def format_attributes(attributes, translator, context: :html, todos: [])
        events, others = attributes.partition { |a| a.is_a?(IR::EventBinding) || a.is_a?(IR::StimulusBinding) }
        spreads, plain_attrs = others.partition { |a| a.is_a?(IR::SpreadAttribute) }

        sym_parts = []
        str_parts = []
        plain_attrs.each do |a|
          append_attribute_part(a, translator, sym_parts, str_parts, context: context, todos: todos)
        end
        sym_parts << data_action_entry(events, translator) if events.any?

        joined = build_attribute_list(sym_parts, str_parts, spreads, translator)
        joined.empty? ? "" : "(#{joined})"
      end

      def append_attribute_part(attribute, translator, sym_parts, str_parts, context:, todos:)
        part = phlex_attribute_part(attribute, translator, context: context, todos: todos)
        return unless part

        (part[:string_key] ? str_parts : sym_parts) << part[:source]
      end

      def build_attribute_list(sym_parts, str_parts, spreads, translator)
        pieces = sym_parts.dup
        pieces << "**{ #{str_parts.join(", ")} }" if str_parts.any?
        pieces.concat(spreads.map { |s| "**#{render_spread(s.expression, translator)}" })
        pieces.join(", ")
      end

      # Emit one attribute as either a {string_key: false, source: "id: @x"}
      # (Ruby-kwarg-safe name) or {string_key: true, source: '"xml:lang" => @x'}
      # (rare; non-identifier name — goes into a **{ ... } splat).
      def phlex_attribute_part(attribute, translator, context:, todos:)
        case attribute
        when IR::StyleBinding then class_attribute_part(attribute.expression, translator)
        when IR::ClassList then { string_key: false, source: "class: #{class_list_to_ruby_string(attribute, translator)}" }
        when IR::Style then { string_key: false, source: "style: #{style_to_ruby_string(attribute, translator)}" }
        when IR::Attribute then plain_attribute_part(attribute, translator, context: context, todos: todos)
        end
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
      def plain_attribute_part(attribute, translator, context:, todos:)
        value_ruby = attribute_value_to_ruby(attribute.name, attribute.value, translator, todos: todos)
        ruby_name = case context
                    when :component then AST::Inflector.underscore(attribute.name)
                    else attribute.name.tr("-", "_")
                    end
        if ruby_name.match?(VALID_IDENTIFIER)
          { string_key: false, source: "#{ruby_name}: #{value_ruby}" }
        else
          { string_key: true, source: "#{attribute.name.inspect} => #{value_ruby}" }
        end
      end

      def attribute_value_to_ruby(name, value, translator, todos:)
        case value
        when true then "true"
        when String then value.inspect
        when IR::Interpolation then interpolated_attribute_value(name, value, translator, todos: todos)
        end
      end

      # Attribute-position interpolation. Two failure modes:
      #   1. Translator returns non-nil but with unresolved identifiers —
      #      the Ruby reference is fine to emit (it'll surface as a
      #      NameError at render time if it's wrong). Inline TODO comments
      #      aren't safe in attribute position (would break hash splat or
      #      method-call syntax), so the marker is suppressed.
      #   2. Translator returns nil — the original JS expression couldn't
      #      be parsed at all (e.g. `<LeftOutlined .../>`, array literals,
      #      template literals with method calls). We emit `nil` for the
      #      kwarg AND record the original expression in `todos` so the
      #      caller can prepend a `# TODO:` comment line above the element.
      def interpolated_attribute_value(name, value, translator, todos:)
        translated = translator.translate(value.expression)
        return translated.ruby if translated

        compact = value.expression.tr("\n", " ").squeeze(" ")
        todos << "attribute #{name.inspect} dropped — couldn't translate: #{compact}"
        "nil"
      end

      def component_invocation_kwargs(props, translator, todos: [])
        events, others = props.partition { |a| a.is_a?(IR::EventBinding) || a.is_a?(IR::StimulusBinding) }
        spreads, plain_attrs = others.partition { |a| a.is_a?(IR::SpreadAttribute) }

        sym_parts = []
        str_parts = []
        plain_attrs.each do |a|
          append_attribute_part(a, translator, sym_parts, str_parts, context: :component, todos: todos)
        end
        sym_parts << data_action_entry(events, translator) if events.any?

        build_attribute_list(sym_parts, str_parts, spreads, translator)
      end

      def class_list_to_ruby_string(class_list, translator)
        parts = class_list.segments.map { |seg| class_segment_to_ruby(seg, translator) }
        %("#{parts.join(" ")}")
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
          %(\#{#{cond_ruby} ? #{segment.class_name.inspect} : ""})
        end
      end

      def style_to_ruby_string(style, translator)
        parts = style.declarations.map { |decl| style_declaration_to_ruby(decl, translator) }
        %("#{parts.join(" ")}")
      end

      def style_declaration_to_ruby(decl, translator)
        value = case decl.value
                when String then decl.value
                when IR::Interpolation
                  translated = translator.translate(decl.value.expression)
                  "\#{#{translated&.ruby || decl.value.expression}}"
                end
        "#{decl.property}: #{value};"
      end

      def render_spread(expression, translator)
        translated = translator.translate(expression)
        translated ? translated.ruby : expression
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
        descriptor.kind == :literal ? %("#{descriptor.body}") : descriptor.body
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
        ["  // TODO: translate from the original JSX handler:"] + commented + [
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
