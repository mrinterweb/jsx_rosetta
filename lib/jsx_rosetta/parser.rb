# frozen_string_literal: true

require_relative "ast"
require_relative "node_bridge"
require_relative "parse_error"

module JsxRosetta
  # Public entry point for JSX → AST parsing.
  #
  # Returns a typed AST::Node tree (rooted at AST::File) that mirrors the
  # Babel AST shape with Ruby ergonomics: snake_case field accessors,
  # source location preservation, traversal helpers, and pattern-matching
  # support.
  class Parser
    def initialize(node_bridge: NodeBridge.new)
      @node_bridge = node_bridge
    end

    def parse(source, typescript: false, source_filename: nil)
      response = @node_bridge.parse(source, typescript: typescript, source_filename: source_filename)

      if response["ok"]
        AST.build(response["ast"])
      else
        error = response["error"] || {}
        raise ParseError.new(error["message"] || "JSX parse failed", line: error["line"], column: error["column"])
      end
    end
  end
end
