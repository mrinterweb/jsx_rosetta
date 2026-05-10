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

  def self.translate(source, backend: :view_component, helpers: nil, layout: :sidecar,
                     typescript: false, source_filename: nil)
    ast = parse(source, typescript: typescript, source_filename: source_filename)
    components = IR.lower_all(ast, source: source)
    backend_instance = backend_for(backend, helpers: helpers, layout: layout)
    components.flat_map { |component| backend_instance.emit(component) }
  end

  def self.backend_for(name, helpers: nil, layout: :sidecar)
    case name
    when :view_component then Backend::ViewComponent.new(helpers: helpers, layout: layout)
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
require_relative "jsx_rosetta/backend"
require_relative "jsx_rosetta/cli"
