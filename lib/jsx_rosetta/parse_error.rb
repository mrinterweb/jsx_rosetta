# frozen_string_literal: true

module JsxRosetta
  class ParseError < Error
    attr_reader :line, :column

    def initialize(message, line: nil, column: nil)
      super(message)
      @line = line
      @column = column
    end

    def to_s
      return super if line.nil?

      "#{super} (#{line}:#{column})"
    end
  end
end
