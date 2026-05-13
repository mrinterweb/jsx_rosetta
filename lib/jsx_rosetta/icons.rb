# frozen_string_literal: true

require "json"

module JsxRosetta
  # Vendored SVG path data for the most common icons referenced by shadcn-shaped
  # JSX. Backends look up icons here to emit standalone Phlex classes alongside
  # the translated component .rb file, so consumers don't have to write icon
  # shims by hand.
  #
  # Refresh `lib/jsx_rosetta/icons/lucide.json` from the upstream Lucide package
  # if you need names that aren't here yet — but verify the path data, since
  # Lucide occasionally tweaks icon shapes between releases.
  module Icons
    LUCIDE_DATA_PATH = File.expand_path("icons/lucide.json", __dir__)

    # Source specifiers that import from a Lucide-shaped icon package.
    # Includes both the React-flavored `lucide-react` and the bare `lucide`
    # package (some shadcn forks use it directly).
    LUCIDE_SOURCE_PATTERN = /\Alucide(-react)?\z/

    def self.lucide_data
      @lucide_data ||= JSON.parse(File.read(LUCIDE_DATA_PATH))
    end

    # Look up the inner-SVG for a Lucide icon. Tolerates both canonical
    # (`ChevronRight`) and legacy `*Icon` (`ChevronRightIcon`) names, since
    # shadcn varies which it imports across components. Returns nil for
    # the degenerate name `"Icon"` (and any empty result after stripping)
    # so callers don't get a misleading data[""] miss.
    def self.lucide_for(name)
      name = name.to_s
      return nil if name.empty? || name == "Icon"

      data = lucide_data
      data[name] || data[name.sub(/Icon\z/, "")]
    end

    # True iff the given `IR::ModuleImport#source` is a known Lucide package.
    def self.lucide_source?(source)
      LUCIDE_SOURCE_PATTERN.match?(source.to_s)
    end
  end
end
