# frozen_string_literal: true

module JsxRosetta
  module Backend
    # Backends consume an IR::Component and emit one or more output files.
    # The return value is an array of File value objects so callers can
    # decide whether to write to disk, return as strings, or compare
    # against a golden fixture.
    class Base
      # A single file produced by a backend.
      #
      #   path     : String — relative output path (e.g. "button_component.rb").
      #   contents : String — the file body.
      File = Data.define(:path, :contents)

      def emit(_ir_component)
        raise NotImplementedError, "#{self.class} must implement #emit"
      end
    end
  end
end
