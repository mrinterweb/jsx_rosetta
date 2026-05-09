# frozen_string_literal: true

require_relative "node_bridge"
require_relative "parse_error"

module JsxRosetta
  # Public entry point for JSX → AST parsing.
  #
  # Phase 0: returns the raw Babel JSON AST as a nested Ruby Hash.
  # Phase 1 will replace this with typed AST::Node trees.
  class Parser
    def initialize(node_bridge: NodeBridge.new)
      @node_bridge = node_bridge
    end

    def parse(source, typescript: false, source_filename: nil)
      response = @node_bridge.parse(source, typescript: typescript, source_filename: source_filename)

      if response["ok"]
        response["ast"]
      else
        error = response["error"] || {}
        raise ParseError.new(error["message"] || "JSX parse failed", line: error["line"], column: error["column"])
      end
    end
  end
end
