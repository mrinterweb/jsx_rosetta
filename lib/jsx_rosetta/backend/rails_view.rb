# frozen_string_literal: true

require_relative "view_component"

module JsxRosetta
  module Backend
    # Emits a translated component as a plain Rails view template
    # (`<snake>.html.erb`) instead of a ViewComponent class + sidecar
    # template. Pages tied to routes are conceptually Rails views, not
    # reusable components — the controller sets `@instance_variables` and
    # the template uses them directly.
    #
    # Reuses the ViewComponent backend's IR-rendering pipeline; only the
    # output shape differs (no Ruby class, no sidecar directory). When the
    # source JSX includes inline event handlers, a Stimulus controller is
    # still emitted as a sibling file alongside the .html.erb.
    class RailsView < ViewComponent
      def emit(component)
        prop_names = component.props.map(&:name)
        prop_names << component.rest_prop_name if component.rest_prop_name
        translator = ExpressionTranslator.new(
          prop_names: prop_names, local_binding_names: component.local_binding_names
        )

        @stimulus_identifier = component.stimulus_methods.any? ? stimulus_identifier(component) : nil

        files = [
          File.new(
            path: "#{AST::Inflector.underscore(component.name)}.html.erb",
            contents: render_erb_template(component, translator)
          )
        ]
        if component.stimulus_methods.any?
          files << File.new(
            path: "#{AST::Inflector.underscore(component.name)}_controller.js",
            contents: render_stimulus_controller_js(component)
          )
        end
        files
      end
    end
  end
end
