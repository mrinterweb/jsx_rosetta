# frozen_string_literal: true

require_relative "ir/types"
require_relative "ir/lowering"

module JsxRosetta
  module IR
    def self.lower(ast_file, source:)
      Lowering.lower(ast_file, source: source)
    end
  end
end
