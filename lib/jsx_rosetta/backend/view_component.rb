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
        translator = ExpressionTranslator.new(prop_names: prop_names)

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
        ["  // TODO: translate from the original JSX handler:"] + commented + [
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

        translated = translator.translate(prop.default.expression)
        translated ? translated.ruby : "nil # TODO: translate #{prop.default.expression.inspect}"
      end

      def render_erb_template(component, translator)
        root = component.body
        root = decorate_with_stimulus_controller(root) if component.stimulus_methods.any? && root.is_a?(IR::Element)
        body = render_ir_node(root, translator, indent: 0)
        body = "#{body}\n" unless body.end_with?("\n")
        prefix = render_local_bindings_todo(component.local_bindings)
        prefix.empty? ? body : "#{prefix}#{body}"
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

      def render_ir_node(node, translator, indent:)
        case node
        when IR::Element then render_element(node, translator, indent: indent)
        when IR::ComponentInvocation then render_component_invocation(node, translator, indent: indent)
        when IR::Fragment then render_fragment(node, translator, indent: indent)
        when IR::Conditional then render_conditional(node, translator, indent: indent)
        when IR::Loop then render_loop(node, translator, indent: indent)
        when IR::Slot then render_slot(node, indent: indent)
        when IR::Text then "#{spaces(indent)}#{node.value}"
        when IR::Interpolation then "#{spaces(indent)}#{interpolation_to_erb(node, translator)}"
        when IR::Comment then "#{spaces(indent)}<%# #{node.text} %>"
        end
      end

      def render_loop(loop_node, translator, indent:)
        iterable_ruby = render_test_expression(loop_node.iterable, translator)
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
        all_literal = descriptors.all? { |d| d.start_with?('"') && d.end_with?('"') }
        joined = if descriptors.size == 1
                   descriptors.first
                 elsif all_literal
                   %("#{descriptors.map { |d| d[1..-2] }.join(" ")}")
                 else
                   %("#{descriptors.map { |d| literal_to_interpolated(d) }.join(" ")}")
                 end
        %("data-action" => #{joined})
      end

      def tag_builder_event_descriptor(event, translator)
        case event
        when IR::EventBinding
          translated = translator.translate(event.handler.expression)
          translated ? translated.ruby : event.handler.expression.inspect
        when IR::StimulusBinding
          %("#{event.event}->#{@stimulus_identifier}##{event.method_name}")
        end
      end

      def literal_to_interpolated(descriptor)
        if descriptor.start_with?('"') && descriptor.end_with?('"')
          descriptor[1..-2]
        else
          "\#{#{descriptor}}"
        end
      end

      def tag_builder_spread(expression, translator)
        translated = translator.translate(expression)
        translated ? translated.ruby : expression
      end

      def render_component_invocation(invocation, translator, indent:)
        helper = @helpers[invocation.name]
        return render_helper_call(invocation, translator, helper, indent: indent) if helper

        kwargs = component_invocation_kwargs(invocation.props, translator)
        new_call = kwargs.empty? ? "#{invocation.name}Component.new" : "#{invocation.name}Component.new(#{kwargs})"

        if invocation.children.empty?
          "#{spaces(indent)}<%= render #{new_call} %>"
        else
          inner = invocation.children.map { |child| render_ir_node(child, translator, indent: indent + 2) }.join("\n")
          "#{spaces(indent)}<%= render #{new_call} do %>\n#{inner}\n#{spaces(indent)}<% end %>"
        end
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

      def render_test_expression(test, translator)
        translated = translator.translate(test.expression)
        translated ? translated.ruby : test.expression
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
        rendered = style.declarations.map { |decl| render_style_declaration(decl, translator) }.join(" ")
        %(style="#{rendered}")
      end

      def render_style_declaration(decl, translator)
        value = case decl.value
                when String then decl.value
                when IR::Interpolation
                  translated = translator.translate(decl.value.expression)
                  "<%= #{translated&.ruby || decl.value.expression} %>"
                end
        "#{decl.property}: #{value};"
      end

      def render_class_list_attribute(class_list, translator)
        parts = class_list.segments.map { |seg| class_segment_for_html(seg, translator) }
        %(class="#{parts.join(" ")}")
      end

      def class_segment_for_html(segment, translator)
        case segment
        when String then segment
        when IR::Interpolation
          translated = translator.translate(segment.expression)
          "<%= #{translated&.ruby || segment.expression} %>"
        when IR::ConditionalSegment
          cond_translated = translator.translate(segment.condition.expression)
          cond_ruby = cond_translated&.ruby || segment.condition.expression
          "<%= #{cond_ruby} ? #{segment.class_name.inspect} : '' %>"
        end
      end

      def class_list_to_ruby_string(class_list, translator)
        parts = class_list.segments.map { |seg| class_segment_for_ruby(seg, translator) }
        %("#{parts.join(" ")}")
      end

      def class_segment_for_ruby(segment, translator)
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
          %(#{attribute.name}="#{interpolation_to_erb(attribute.value, translator)}")
        end
      end

      def render_style_binding(binding, translator)
        translated = translator.translate(binding.expression)
        if double_quoted_ruby_string?(translated&.ruby)
          %(class="#{inlined_class_string(translated.ruby)}")
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
      def inlined_class_string(ruby_string)
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
        parts = style.declarations.map do |decl|
          value = case decl.value
                  when String then decl.value
                  when IR::Interpolation
                    translated = translator.translate(decl.value.expression)
                    "\#{#{translated&.ruby || decl.value.expression}}"
                  end
          "#{decl.property}: #{value};"
        end
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
