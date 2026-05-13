# frozen_string_literal: true

require_relative "ir/types"
require_relative "ir/radix_registry"
require_relative "ir/lowering"

module JsxRosetta
  module IR
    def self.lower(ast_file, source:, keep_slot: false)
      Lowering.lower(ast_file, source: source, keep_slot: keep_slot)
    end

    def self.lower_all(ast_file, source:, keep_slot: false)
      Lowering.lower_all(ast_file, source: source, keep_slot: keep_slot)
    end
  end
end
