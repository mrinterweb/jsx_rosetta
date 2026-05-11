# frozen_string_literal: true

require_relative "../ast/inflector"
require_relative "../ir/types"
require_relative "base"

module JsxRosetta
  module Backend
    # Emits a Rails ViewComponent (one Ruby class + one ERB template)
    # from an IR::Component.
    #
    # Phase 3 scope:
    #   - Single component per emit.
    #   - JSX prop names lowered to snake_case Ruby kwargs and matching
    #     `@instance_variable` assignments.
    #   - JS expressions translated via ExpressionTranslator where the
    #     shape is recognized; otherwise emitted as a TODO marker plus
    #     verbatim source.
    #   - HTML attributes emitted directly; className / template-literal
    #     class expressions inlined into the `class="..."` attribute.
    #
    # Phase 4a additions:
    #   - `children` prop is treated as ViewComponent's default content
    #     slot: it's filtered out of the initializer and rendered as
    #     `<%= content %>` wherever the IR has IR::Slot(name: "children").
    #   - IR::Conditional renders as `<% if %>...<% else %>...<% end %>`.
    class ViewComponent < Base
      DEFAULT_SLOT_NAME = "children"
      VOID_ELEMENTS = %w[area base br col embed hr img input link meta param source track wbr].freeze

      # Structured intermediate for tag_builder_data_action — avoids the
      # fragile "parse what you just rendered" pattern. :literal is a raw
      # action token like `"click->foo#bar"`; :ruby is a Ruby expression
      # whose value is the action string (e.g. `event.handler.expression`).
      EventDescriptor = Data.define(:kind, :body)

      # JSX component names that have a direct Rails view-helper analog.
      # Override per-instance via `ViewComponent.new(helpers: {...})`, or
      # disable by passing `helpers: false`.
      DEFAULT_HELPERS = {
        "Link" => { method: :link_to, positional: :href }.freeze,
        "Image" => { method: :image_tag, positional: :src }.freeze
      }.freeze

      def initialize(helpers: nil, layout: :sidecar)
        super()
        @helpers = case helpers
                   when nil then DEFAULT_HELPERS
                   when false then {}
                   else helpers
                   end
        unless %i[sidecar flat].include?(layout)
          raise ArgumentError, "unknown layout: #{layout.inspect} (expected :sidecar or :flat)"
        end

        @layout = layout
      end

      def emit(component)
        prop_names = component.props.map(&:name)
        prop_names << component.rest_prop_name if component.rest_prop_name
        translator = ExpressionTranslator.new(
          prop_names: prop_names, local_binding_names: component.local_binding_names
        )

        base_name = "#{AST::Inflector.underscore(component.name)}_component"
        @stimulus_identifier = component.stimulus_methods.any? ? stimulus_identifier(component) : nil

        files = [
          File.new(path: "#{base_name}.rb", contents: render_ruby_class(component, translator)),
          File.new(path: erb_path(base_name), contents: render_erb_template(component, translator))
        ]
        if component.stimulus_methods.any?
          files << File.new(
            path: stimulus_path(component, base_name),
            contents: render_stimulus_controller_js(component)
          )
        end
        files
      end

      def erb_path(base_name)
        @layout == :sidecar ? "#{base_name}/#{base_name}.html.erb" : "#{base_name}.html.erb"
      end

      def stimulus_path(component, base_name)
        controller_filename = "#{AST::Inflector.underscore(component.name)}_controller.js"
        @layout == :sidecar ? "#{base_name}/#{controller_filename}" : controller_filename
      end

      def stimulus_identifier(component)
        AST::Inflector.underscore(component.name).tr("_", "-")
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

      private

      def initializable_props(component)
        component.props.reject { |prop| prop.name == DEFAULT_SLOT_NAME }
      end

      def render_ruby_class(component, translator)
        props = initializable_props(component)
        rest_name = component.rest_prop_name

        body = render_class_with_optional_props(component, props, rest_name, translator)
        body = inject_render_method_skeletons(body, component)

        prefix = render_module_bindings_prefix(component)
        prefix.empty? ? body : insert_module_bindings_prefix(body, prefix)
      end

      def render_class_with_optional_props(component, props, rest_name, translator)
        if props.empty? && rest_name.nil?
          <<~RUBY
            # frozen_string_literal: true

            class #{component.name}Component < ::ViewComponent::Base
            end
          RUBY
        else
          render_ruby_class_with_props(component, props, rest_name, translator)
        end
      end

      # For each RenderMethod, emit a method skeleton on the class just
      # before the closing `end`. ERB-rendered VC bodies don't translate
      # cleanly to Ruby methods (Phlex does — see its renderer), so the
      # skeleton stays empty and the JSX source is preserved as a comment
      # for the reviewer to translate by hand.
      def inject_render_method_skeletons(body, component)
        return body if component.render_methods.empty?

        skeletons = component.render_methods.map { |rm| render_method_skeleton(rm) }
        body.sub(/(\n)end\n\z/, "\n\n#{skeletons.join("\n\n")}\\1end\n")
      end

      def render_method_skeleton(render_method)
        snake_params = render_method.params.map { |p| AST::Inflector.underscore(p) }
        signature = snake_params.empty? ? render_method.name : "#{render_method.name}(#{snake_params.join(", ")})"
        [
          "  # TODO: translate the JSX body for #{render_method.name} — was a",
          "  # local arrow returning JSX in the source component.",
          "  def #{signature}",
          "    \"\"",
          "  end"
        ].join("\n")
      end

      def render_module_bindings_prefix(component)
        return "" if component.module_bindings.empty?

        lines = ["# TODO: module-level constants — translate to Ruby constants " \
                 "or move to a Rails initializer:"]
        component.module_bindings.each { |b| lines.concat(comment_lines(b.source)) }
        "#{lines.join("\n")}\n"
      end

      # The class body already starts with the magic comment — splice the
      # module-bindings prefix in between so it lands above the class.
      def insert_module_bindings_prefix(body, prefix)
        magic = "# frozen_string_literal: true\n\n"
        return "#{prefix}#{body}" unless body.start_with?(magic)

        "#{magic}#{prefix}#{body[magic.length..]}"
      end

      def comment_lines(source)
        source.split("\n").map { |line| "#   #{line}" }
      end

      def render_ruby_class_with_props(component, props, rest_name, translator)
        kwargs = props.map { |prop| ruby_kwarg(prop, translator) }
        kwargs << "**#{rest_name}" if rest_name

        assignments = props.map do |prop|
          snake = AST::Inflector.underscore(prop.name)
          "    @#{snake} = #{snake}"
        end
        assignments << "    @#{rest_name} = #{rest_name}" if rest_name

        <<~RUBY
          # frozen_string_literal: true

          class #{component.name}Component < ::ViewComponent::Base
            def initialize(#{kwargs.join(", ")})
          #{assignments.join("\n")}
            end
          end
        RUBY
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
        when IR::ObjectLiteral then render_object_literal_default(prop.default, translator)
        when IR::ArrayLiteral then render_array_literal_default(prop.default, translator)
        else "nil"
        end
      end

      def render_object_literal_default(object_literal, translator)
        pairs = object_literal.properties.map do |(key, value)|
          snake = AST::Inflector.underscore(key)
          key_str = snake.match?(/\A[a-z_][a-z0-9_]*\z/i) ? "#{snake}:" : "#{key.inspect} =>"
          "#{key_str} #{render_default_inline_value(value, translator)}"
        end
        "{ #{pairs.join(", ")} }"
      end

      def render_array_literal_default(array_literal, translator)
        parts = array_literal.elements.map { |el| el.nil? ? "nil" : render_default_inline_value(el, translator) }
        "[#{parts.join(", ")}]"
      end

      def render_default_inline_value(value, translator)
        case value
        when IR::ObjectLiteral then render_object_literal_default(value, translator)
        when IR::ArrayLiteral then render_array_literal_default(value, translator)
        when IR::Interpolation
          translated = translator.translate(value.expression)
          translated ? translated.ruby : "nil"
        when String then value.inspect
        when true then "true"
        else "nil"
        end
      end

      def render_erb_template(component, translator)
        root = component.body
        root = decorate_with_stimulus_controller(root) if component.stimulus_methods.any? && root.is_a?(IR::Element)
        body = render_ir_node(root, translator, indent: 0)
        body = "#{body}\n" unless body.end_with?("\n")

        prefix = String.new
        prefix << render_react_hooks_todo(component.react_hooks)
        prefix << render_local_bindings_todo(component.local_bindings)
        "#{prefix}#{body}"
      end

      def decorate_with_stimulus_controller(element)
        attr = IR::Attribute.new(name: "data-controller", value: @stimulus_identifier)
        IR::Element.new(tag: element.tag, attributes: [attr] + element.attributes, children: element.children)
      end

      def render_local_bindings_todo(bindings)
        return "" if bindings.empty?

        unique_sources = bindings.map(&:source).uniq
        lines = ["<%# TODO: translate JS to Ruby — original:"]
        unique_sources.each { |src| lines << "    #{src}" }
        lines << "%>"
        "#{lines.join("\n")}\n"
      end

      def render_react_hooks_todo(hooks)
        return "" if hooks.empty?

        lines = [
          "<%# TODO: React hooks detected. None translate automatically. Hotwire/Stimulus",
          "    handles behavior; controllers/views handle state; turbo-frames handle async",
          "    loading. Original source:"
        ]
        hooks.each { |hook| lines << "    #{hook.source}" }
        lines << "%>"
        "#{lines.join("\n")}\n"
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
        when IR::Text then "#{spaces(indent)}#{node.value}"
        when IR::Interpolation then "#{spaces(indent)}#{interpolation_to_erb(node, translator)}"
        when IR::Comment then "#{spaces(indent)}<%# #{node.text} %>"
        end
      end

      # `{renderHeader(arg)}` → `<%= render_header(arg) %>`. The matching
      # method definition is emitted on the component class via
      # `render_render_methods_section`. The class method returns an
      # HTML-safe string (Rails' `content_tag` / `safe_join` is the
      # canonical approach), and `<%= %>` interpolates it into the template.
      def render_local_render_call(call, translator, indent:)
        if call.args.empty?
          "#{spaces(indent)}<%= #{call.method_name} %>"
        else
          arg_sources = call.args.map do |arg|
            translated = translator.translate(arg.expression)
            translated ? translated.ruby : arg.expression
          end
          "#{spaces(indent)}<%= #{call.method_name}(#{arg_sources.join(", ")}) %>"
        end
      end

      def render_orphan_render_prop(render_prop, translator, indent:)
        translator.with_locals(render_prop.params) do
          render_ir_node(render_prop.body, translator, indent: indent)
        end
      end

      def render_loop(loop_node, translator, indent:)
        iterable_ruby = render_loop_iterable(loop_node.iterable, translator)
        js_bindings = [loop_node.item_binding, loop_node.index_binding].compact
        ruby_bindings = js_bindings.map { |name| AST::Inflector.underscore(name) }
        binding_str = "|#{ruby_bindings.join(", ")}|"

        body = translator.with_locals(js_bindings) do
          render_ir_node(loop_node.body, translator, indent: indent + 2)
        end

        [
          "#{spaces(indent)}<% #{iterable_ruby}.each do #{binding_str} %>",
          body,
          "#{spaces(indent)}<% end %>"
        ].join("\n")
      end

      def render_loop_iterable(iterable, translator)
        case iterable
        when IR::ArrayLiteral then render_array_literal_default(iterable, translator)
        when IR::Interpolation then render_test_expression(iterable, translator)
        else "[]"
        end
      end

      def render_element(element, translator, indent:)
        return render_element_with_tag_builder(element, translator, indent: indent) if needs_tag_builder?(element)

        attrs = render_attributes(element.attributes, translator)
        attrs_segment = attrs.empty? ? "" : " #{attrs}"

        return "#{spaces(indent)}<#{element.tag}#{attrs_segment} />" if VOID_ELEMENTS.include?(element.tag)

        opening = "<#{element.tag}#{attrs_segment}>"
        closing = "</#{element.tag}>"

        if element.children.empty?
          "#{spaces(indent)}#{opening}#{closing}"
        else
          inner = element.children.map { |child| render_ir_node(child, translator, indent: indent + 2) }.join("\n")
          "#{spaces(indent)}#{opening}\n#{inner}\n#{spaces(indent)}#{closing}"
        end
      end

      def needs_tag_builder?(element)
        element.attributes.any?(IR::SpreadAttribute)
      end

      def render_element_with_tag_builder(element, translator, indent:)
        builder_args = render_tag_builder_args(element.attributes, translator)
        prefix = "<%= tag.#{element.tag}(#{builder_args})"

        if VOID_ELEMENTS.include?(element.tag) || element.children.empty?
          "#{spaces(indent)}#{prefix} %>"
        else
          inner = element.children.map { |child| render_ir_node(child, translator, indent: indent + 2) }.join("\n")
          "#{spaces(indent)}#{prefix} do %>\n#{inner}\n#{spaces(indent)}<% end %>"
        end
      end

      def render_tag_builder_args(attributes, translator)
        events, others = attributes.partition { |attr| attr.is_a?(IR::EventBinding) || attr.is_a?(IR::StimulusBinding) }
        spreads, plain = others.partition { |attr| attr.is_a?(IR::SpreadAttribute) }

        pieces = plain.filter_map { |attr| tag_builder_kwarg(attr, translator) }
        pieces << tag_builder_data_action(events, translator) if events.any?
        pieces.concat(spreads.map { |s| "**#{tag_builder_spread(s.expression, translator)}" })
        pieces.join(", ")
      end

      def tag_builder_kwarg(attribute, translator)
        case attribute
        when IR::StyleBinding
          translated = translator.translate(attribute.expression)
          ruby = translated ? translated.ruby : attribute.expression.inspect
          "class: #{ruby}"
        when IR::ClassList
          "class: #{class_list_to_ruby_string(attribute, translator)}"
        when IR::Style
          "style: #{style_to_ruby_string(attribute, translator)}"
        when IR::Attribute
          tag_builder_plain_kwarg(attribute, translator)
        end
      end

      def tag_builder_plain_kwarg(attribute, translator)
        key = attribute.name.match?(/\A[a-z_][a-z0-9_]*\z/i) ? "#{attribute.name}:" : "#{attribute.name.inspect} =>"
        "#{key} #{tag_builder_value(attribute.value, translator)}"
      end

      def tag_builder_value(value, translator)
        case value
        when true then "true"
        when String then value.inspect
        when IR::Interpolation
          translated = translator.translate(value.expression)
          translated ? translated.ruby : value.expression.inspect
        end
      end

      def tag_builder_data_action(events, translator)
        descriptors = events.map { |event| tag_builder_event_descriptor(event, translator) }
        joined = case descriptors
                 in [single]
                   render_single_event_descriptor(single)
                 else
                   %("#{descriptors.map { |d| descriptor_in_string(d) }.join(" ")}")
                 end
        %("data-action" => #{joined})
      end

      def tag_builder_event_descriptor(event, translator)
        case event
        when IR::EventBinding
          translated = translator.translate(event.handler.expression)
          if translated
            EventDescriptor.new(:ruby, translated.ruby)
          else
            EventDescriptor.new(:ruby, event.handler.expression.inspect)
          end
        when IR::StimulusBinding
          EventDescriptor.new(:literal, "#{event.event}->#{@stimulus_identifier}##{event.method_name}")
        end
      end

      def render_single_event_descriptor(descriptor)
        descriptor.kind == :literal ? %("#{descriptor.body}") : descriptor.body
      end

      # Render a descriptor inline inside a Ruby string literal: literals
      # are spliced verbatim, ruby expressions become `#{...}`.
      def descriptor_in_string(descriptor)
        descriptor.kind == :literal ? descriptor.body : "\#{#{descriptor.body}}"
      end

      # Wrap the spread expression in `(… || {})` so a nil-valued prop
      # default doesn't raise at render time. `<div {...maybeNil}>` →
      # `**(@maybe_nil || {})`. Cheap to emit unconditionally; the
      # `|| {}` shortcuts on non-nil values.
      def tag_builder_spread(expression, translator)
        translated = translator.translate(expression)
        ruby = translated ? translated.ruby : expression
        "(#{ruby} || {})"
      end

      def render_component_invocation(invocation, translator, indent:)
        helper = @helpers[invocation.name]
        return render_helper_call(invocation, translator, helper, indent: indent) if helper

        kwargs = component_invocation_kwargs(invocation.props, translator)
        class_name = component_class_name(invocation.name)
        new_call = kwargs.empty? ? "#{class_name}.new" : "#{class_name}.new(#{kwargs})"

        render_prop = invocation.children.find { |c| c.is_a?(IR::RenderProp) }
        if render_prop
          render_component_with_render_prop(new_call, render_prop, translator, indent)
        elsif invocation.children.empty?
          "#{spaces(indent)}<%= render #{new_call} %>"
        else
          inner = invocation.children.map { |child| render_ir_node(child, translator, indent: indent + 2) }.join("\n")
          "#{spaces(indent)}<%= render #{new_call} do %>\n#{inner}\n#{spaces(indent)}<% end %>"
        end
      end

      def render_component_with_render_prop(new_call, render_prop, translator, indent)
        snake_params = render_prop.params.map { |p| AST::Inflector.underscore(p) }
        param_str = snake_params.empty? ? "" : " |#{snake_params.join(", ")}|"
        inner = translator.with_locals(render_prop.params) do
          render_ir_node(render_prop.body, translator, indent: indent + 2)
        end
        "#{spaces(indent)}<%= render #{new_call} do#{param_str} %>\n#{inner}\n#{spaces(indent)}<% end %>"
      end

      # JSX `<Foo.Bar>` → Ruby `Foo::BarComponent`. Plain `<Card>` stays as
      # `CardComponent`. Each member-expression segment joins with `::`,
      # and `Component` suffixes the leaf so the result is a constant path
      # the host app can autoload.
      def component_class_name(jsx_tag)
        return "#{jsx_tag}Component" unless jsx_tag.include?(".")

        "#{jsx_tag.split(".").join("::")}Component"
      end

      def render_helper_call(invocation, translator, helper, indent:)
        call = build_helper_call(invocation, translator, helper)
        if invocation.children.empty?
          "#{spaces(indent)}<%= #{call} %>"
        else
          inner = invocation.children.map { |child| render_ir_node(child, translator, indent: indent + 2) }.join("\n")
          "#{spaces(indent)}<%= #{call} do %>\n#{inner}\n#{spaces(indent)}<% end %>"
        end
      end

      def build_helper_call(invocation, translator, helper)
        positional_attr = find_positional_attr(invocation.props, helper[:positional])
        remaining = positional_attr ? invocation.props.reject { |p| p.equal?(positional_attr) } : invocation.props

        parts = []
        parts << component_kwarg_value(positional_attr.value, translator) if positional_attr
        kwargs = component_invocation_kwargs(remaining, translator)
        parts << kwargs unless kwargs.empty?

        parts.empty? ? helper[:method].to_s : "#{helper[:method]}(#{parts.join(", ")})"
      end

      def find_positional_attr(props, positional)
        return nil unless positional

        name = positional.to_s
        props.find { |p| p.is_a?(IR::Attribute) && p.name == name }
      end

      def component_invocation_kwargs(props, translator)
        spreads, others = props.partition { |attr| attr.is_a?(IR::SpreadAttribute) }
        parts = others.filter_map { |attr| component_kwarg(attr, translator) }
        parts.concat(spreads.map { |s| "**#{tag_builder_spread(s.expression, translator)}" })
        parts.join(", ")
      end

      def render_fragment(fragment, translator, indent:)
        fragment.children.map { |child| render_ir_node(child, translator, indent: indent) }.join("\n")
      end

      def render_conditional(conditional, translator, indent:)
        test_ruby = render_test_expression(conditional.test, translator)
        lines = ["#{spaces(indent)}<% if #{test_ruby} %>"]
        lines << render_ir_node(conditional.consequent, translator, indent: indent + 2)
        if conditional.alternate
          lines << "#{spaces(indent)}<% else %>"
          lines << render_ir_node(conditional.alternate, translator, indent: indent + 2)
        end
        lines << "#{spaces(indent)}<% end %>"
        lines.join("\n")
      end

      # A translated value of `"nil"` is treated as untranslatable: the
      # translator emits `"nil"` for known-local bindings (so the file
      # loads as a leaf reference), but driving an `<% if %>` with `nil`
      # silently disables the whole branch. Fall back to the verbatim
      # expression so the human reviewer sees what needs translating.
      def render_test_expression(test, translator)
        translated = translator.translate(test.expression)
        return translated.ruby if translated && translated.ruby != "nil"

        test.expression
      end

      def render_slot(slot, indent:)
        if slot.name == DEFAULT_SLOT_NAME
          "#{spaces(indent)}<%= content %>"
        else
          # Named slots become Phase 4d work; for now flag them.
          "#{spaces(indent)}<%# TODO: named slot #{slot.name.inspect} %>"
        end
      end

      def render_attributes(attributes, translator)
        events, others = attributes.partition { |attr| attr.is_a?(IR::EventBinding) || attr.is_a?(IR::StimulusBinding) }
        rendered = others.filter_map { |attr| render_attribute(attr, translator) }
        rendered << render_data_action(events, translator) if events.any?
        rendered.join(" ")
      end

      def render_attribute(attribute, translator)
        case attribute
        when IR::StyleBinding then render_style_binding(attribute, translator)
        when IR::ClassList then render_class_list_attribute(attribute, translator)
        when IR::Style then render_style(attribute, translator)
        when IR::Attribute then render_plain_attribute(attribute, translator)
        end
      end

      def render_style(style, translator)
        rendered = style.declarations.map { |decl| style_declaration(decl, translator, format: :erb) }.join(" ")
        %(style="#{rendered}")
      end

      def render_class_list_attribute(class_list, translator)
        parts = class_list.segments.map { |seg| class_segment(seg, translator, format: :erb) }
        %(class="#{parts.join(" ")}")
      end

      def class_list_to_ruby_string(class_list, translator)
        parts = class_list.segments.map { |seg| class_segment(seg, translator, format: :ruby_string) }
        %("#{parts.join(" ")}")
      end

      # Render one IR::Style declaration in either ERB-template form
      # (`color: <%= @c %>;`) or Ruby-string-interpolation form
      # (`color: #{@c};`).
      def style_declaration(decl, translator, format:)
        value = case decl.value
                when String then decl.value
                when IR::Interpolation then interpolation_value(decl.value.expression, translator, format: format)
                end
        "#{decl.property}: #{value};"
      end

      # Render one ClassList segment in either ERB-template form or Ruby
      # string-interpolation form.
      def class_segment(segment, translator, format:)
        case segment
        when String then segment
        when IR::Interpolation then interpolation_value(segment.expression, translator, format: format)
        when IR::ConditionalSegment then conditional_class_segment(segment, translator, format: format)
        end
      end

      def interpolation_value(expression, translator, format:)
        translated = translator.translate(expression)
        ruby = translated&.ruby || expression
        format == :erb ? "<%= #{ruby} %>" : "\#{#{ruby}}"
      end

      def conditional_class_segment(segment, translator, format:)
        cond_translated = translator.translate(segment.condition.expression)
        cond_ruby = cond_translated&.ruby || segment.condition.expression
        if format == :erb
          "<%= #{cond_ruby} ? #{segment.class_name.inspect} : '' %>"
        else
          %(\#{#{cond_ruby} ? #{segment.class_name.inspect} : ""})
        end
      end

      def render_data_action(events, translator)
        parts = events.map { |event| render_event_handler(event, translator) }
        %(data-action="#{parts.join(" ")}")
      end

      def render_event_handler(event, translator)
        case event
        when IR::EventBinding
          translated = translator.translate(event.handler.expression)
          ruby = translated ? translated.ruby : event.handler.expression
          "<%= #{ruby} %>"
        when IR::StimulusBinding
          "#{event.event}->#{@stimulus_identifier}##{event.method_name}"
        end
      end

      def render_plain_attribute(attribute, translator)
        case attribute.value
        when true then attribute.name
        when String then %(#{attribute.name}="#{attribute.value}")
        when IR::Interpolation
          %(#{attribute.name}="#{plain_attribute_value_erb(attribute.value, translator)}")
        end
      end

      # Try to inline the attribute value rather than wrapping it in `<%= %>`.
      # If the translator produces a Ruby double-quoted string with `#{…}`
      # interpolations (typical for template-literal hrefs etc.), emit the
      # literal portions literally and the interpolations as ERB tags.
      def plain_attribute_value_erb(interpolation, translator)
        translated = translator.translate(interpolation.expression)
        if double_quoted_ruby_string?(translated&.ruby) && translated.unresolved_identifiers.empty?
          inlined_ruby_string(translated.ruby)
        else
          interpolation_to_erb(interpolation, translator)
        end
      end

      def render_style_binding(binding, translator)
        translated = translator.translate(binding.expression)
        if double_quoted_ruby_string?(translated&.ruby)
          %(class="#{inlined_ruby_string(translated.ruby)}")
        elsif translated
          %(class="<%= #{translated.ruby} %>")
        else
          %(class="<%# TODO: translate #{binding.expression.inspect} %><%= #{binding.expression} %>")
        end
      end

      def double_quoted_ruby_string?(ruby)
        ruby.is_a?(String) && ruby.start_with?('"') && ruby.end_with?('"')
      end

      # Given a Ruby double-quoted string with #{...} interpolations, emit it
      # in ERB template form: the literal portions stay literal, and each
      # interpolation becomes an ERB tag.
      #
      # `"btn btn-#{@variant}"` → `btn btn-<%= @variant %>`
      def inlined_ruby_string(ruby_string)
        inner = ruby_string[1..-2]
        inner.gsub(/\#\{([^}]+)\}/) { "<%= #{::Regexp.last_match(1)} %>" }
      end

      def interpolation_to_erb(interpolation, translator)
        translated = translator.translate(interpolation.expression)
        unless translated
          return "<%# TODO: translate #{interpolation.expression.inspect} %>" \
                 "<%= #{interpolation.expression} %>"
        end

        unresolved = translated.unresolved_identifiers
        return "<%= #{translated.ruby} %>" if unresolved.empty?

        names = unresolved.map(&:inspect).join(", ")
        "<%# TODO: unresolved identifier #{names} %><%= #{translated.ruby} %>"
      end

      def component_kwarg(attribute, translator)
        case attribute
        when IR::Attribute
          component_attribute_kwarg(attribute, translator)
        when IR::StyleBinding
          translated = translator.translate(attribute.expression)
          ruby = translated ? translated.ruby : attribute.expression.inspect
          "class: #{ruby}"
        when IR::ClassList
          "class: #{class_list_to_ruby_string(attribute, translator)}"
        when IR::Style
          "style: #{style_to_ruby_string(attribute, translator)}"
        end
      end

      def style_to_ruby_string(style, translator)
        parts = style.declarations.map { |decl| style_declaration(decl, translator, format: :ruby_string) }
        %("#{parts.join(" ")}")
      end

      def component_attribute_kwarg(attribute, translator)
        value = component_kwarg_value(attribute.value, translator)
        if attribute.name.match?(/\A[a-z_][a-z0-9_]*\z/i)
          name = AST::Inflector.underscore(attribute.name)
          "#{name}: #{value}"
        else
          "#{attribute.name.inspect} => #{value}"
        end
      end

      def component_kwarg_value(value, translator)
        case value
        when true then "true"
        when String then value.inspect
        when IR::Interpolation
          translated = translator.translate(value.expression)
          translated ? translated.ruby : "nil # TODO: translate #{value.expression.inspect}"
        end
      end

      def spaces(count)
        " " * count
      end
    end
  end
end
