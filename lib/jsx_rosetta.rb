# frozen_string_literal: true

require_relative "jsx_rosetta/version"

module JsxRosetta
  class Error < StandardError; end

  def self.parse(source, typescript: false, source_filename: nil)
    Parser.new.parse(source, typescript: typescript, source_filename: source_filename)
  end

  def self.lower(source, typescript: false, source_filename: nil)
    ast = parse(source, typescript: typescript, source_filename: source_filename)
    IR.lower(ast, source: source)
  end

  def self.translate(source, backend: :view_component, backend_options: {},
                     typescript: false, source_filename: nil, **legacy_options)
    ast = parse(source, typescript: typescript, source_filename: source_filename)
    components = IR.lower_all(ast, source: source)
    backend_instance = backend_for(backend, **legacy_options, **backend_options)
    components.flat_map { |component| backend_instance.emit(component, source_filename: source_filename) }
  end

  def self.backend_for(name, **options)
    case name
    when :view_component then Backend::ViewComponent.new(**options.slice(:helpers, :layout))
    when :rails_view then Backend::RailsView.new(**options.slice(:helpers, :layout))
    when :phlex then Backend::Phlex.new(**options.slice(:suffix, :namespace))
    else
      raise Error, "unknown backend: #{name.inspect}"
    end
  end
end

require_relative "jsx_rosetta/parse_error"
require_relative "jsx_rosetta/node_bridge"
require_relative "jsx_rosetta/parser"
require_relative "jsx_rosetta/ir"
require_relative "jsx_rosetta/routes"
require_relative "jsx_rosetta/icons"
require_relative "jsx_rosetta/backend"
require_relative "jsx_rosetta/cli"
