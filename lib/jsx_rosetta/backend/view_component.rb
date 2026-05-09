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
    #   - JSX prop names are lowered to snake_case Ruby kwargs and matching
    #     `@instance_variable` assignments.
    #   - JS expressions are translated to Ruby via ExpressionTranslator
    #     where the shape is recognized; everything else falls back to a
    #     verbatim emission with an ERB TODO marker so the human can fix.
    #   - HTML attributes are emitted directly; className / template-literal
    #     class expressions are inlined into a `class="..."` attribute.
    #   - children is currently a plain prop, not a ViewComponent slot;
    #     Phase 4 will lift it (and other slot-shaped props) into proper
    #     ViewComponent renders_one / content semantics.
    class ViewComponent < Base
      def emit(component)
        prop_names = component.props.map(&:name)
        translator = ExpressionTranslator.new(prop_names: prop_names)

        base_name = "#{AST::Inflector.underscore(component.name)}_component"

        [
          File.new(path: "#{base_name}.rb", contents: render_ruby_class(component, translator)),
          File.new(path: "#{base_name}.html.erb", contents: render_erb_template(component, translator))
        ]
      end

      private

      def render_ruby_class(component, translator)
        kwargs = component.props.map { |prop| ruby_kwarg(prop, translator) }.join(", ")
        assignments = component.props.map do |prop|
          snake = AST::Inflector.underscore(prop.name)
          "    @#{snake} = #{snake}"
        end.join("\n")

        <<~RUBY
          # frozen_string_literal: true

          class #{component.name}Component < ::ViewComponent::Base
            def initialize(#{kwargs})
          #{assignments}
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
        body = render_ir_node(component.body, translator, indent: 0)
        body.end_with?("\n") ? body : "#{body}\n"
      end

      def render_ir_node(node, translator, indent:)
        case node
        when IR::Element then render_element(node, translator, indent: indent)
        when IR::ComponentInvocation then render_component_invocation(node, translator, indent: indent)
        when IR::Fragment then render_fragment(node, translator, indent: indent)
        when IR::Text then "#{spaces(indent)}#{node.value}"
        when IR::Interpolation then "#{spaces(indent)}#{interpolation_to_erb(node, translator)}"
        end
      end

      def render_element(element, translator, indent:)
        attrs = render_attributes(element.attributes, translator)
        attrs_segment = attrs.empty? ? "" : " #{attrs}"
        opening = "<#{element.tag}#{attrs_segment}>"
        closing = "</#{element.tag}>"

        if element.children.empty?
          "#{spaces(indent)}#{opening}#{closing}"
        else
          inner = element.children.map { |child| render_ir_node(child, translator, indent: indent + 2) }.join("\n")
          "#{spaces(indent)}#{opening}\n#{inner}\n#{spaces(indent)}#{closing}"
        end
      end

      def render_component_invocation(invocation, translator, indent:)
        kwargs = invocation.props.filter_map { |attr| component_kwarg(attr, translator) }.join(", ")
        new_call = kwargs.empty? ? "#{invocation.name}Component.new" : "#{invocation.name}Component.new(#{kwargs})"

        if invocation.children.empty?
          "#{spaces(indent)}<%= render #{new_call} %>"
        else
          inner = invocation.children.map { |child| render_ir_node(child, translator, indent: indent + 2) }.join("\n")
          "#{spaces(indent)}<%= render #{new_call} do %>\n#{inner}\n#{spaces(indent)}<% end %>"
        end
      end

      def render_fragment(fragment, translator, indent:)
        fragment.children.map { |child| render_ir_node(child, translator, indent: indent) }.join("\n")
      end

      def render_attributes(attributes, translator)
        attributes.filter_map { |attr| render_attribute(attr, translator) }.join(" ")
      end

      def render_attribute(attribute, translator)
        case attribute
        when IR::StyleBinding then render_style_binding(attribute, translator)
        when IR::Attribute then render_plain_attribute(attribute, translator)
        end
      end

      def render_plain_attribute(attribute, translator)
        return nil if attribute.name == "__spread__"

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
        if translated
          "<%= #{translated.ruby} %>"
        else
          "<%# TODO: translate #{interpolation.expression.inspect} %><%= #{interpolation.expression} %>"
        end
      end

      def component_kwarg(attribute, translator)
        case attribute
        when IR::Attribute
          name = AST::Inflector.underscore(attribute.name)
          value = component_kwarg_value(attribute.value, translator)
          "#{name}: #{value}"
        when IR::StyleBinding
          translated = translator.translate(binding_expression(attribute))
          ruby = translated ? translated.ruby : binding_expression(attribute).inspect
          "class: #{ruby}"
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

      def binding_expression(style_binding)
        style_binding.expression
      end

      def spaces(count)
        " " * count
      end
    end
  end
end
