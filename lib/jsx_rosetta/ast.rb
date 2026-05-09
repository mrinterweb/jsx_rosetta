# frozen_string_literal: true

require_relative "ast/inflector"
require_relative "ast/node"
require_relative "ast/types"
require_relative "ast/visitor"

module JsxRosetta
  module AST
    # Wrap a parsed Babel JSON tree (Hash) into typed AST::Node objects.
    def self.build(json_hash)
      Node.wrap(json_hash)
    end
  end
end
