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
end

require_relative "jsx_rosetta/parse_error"
require_relative "jsx_rosetta/node_bridge"
require_relative "jsx_rosetta/parser"
require_relative "jsx_rosetta/ir"
