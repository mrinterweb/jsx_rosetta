# frozen_string_literal: true

require "pathname"

require_relative "ast/inflector"
require_relative "version"

module JsxRosetta
  # Walks a Next.js-style `pages/` directory tree and produces a Rails
  # `config/routes.rb` skeleton.
  #
  # The route table is derived from path shape alone — no JS parsing.
  # Next.js filesystem routing is fully encoded in directory layout, so
  # the input here is `Dir.glob` plus the file extension filter.
  #
  # Slice 1 of plans/nextjs_pages_to_rails.md: routes only. No file
  # moves, no controller skeletons, no class renames.
  module PagesRouting
    Route = Data.define(:rails_path, :controller, :action, :source_path) do
      # Extracts the named URL params from `rails_path` in order. Catches
      # `:foo`, `*rest`, and `(/*extra)`-style optional catch-alls.
      def url_params
        rails_path.scan(/[:*]([a-z_][a-z0-9_]*)/i).flatten
      end
    end

    Skipped = Data.define(:source_path, :reason)
    ControllerFile = Data.define(:path, :contents)

    SKIPPED_LEAVES = {
      "_app" => "Next.js application wrapper — convert to app/views/layouts/application.html.erb",
      "_document" => "Next.js HTML document — typically subsumed by Rails layout",
      "_error" => "Next.js error handler — wire to config.exceptions_app",
      "404" => "404 page — wire to config.exceptions_app",
      "500" => "500 page — wire to config.exceptions_app"
    }.freeze

    DEFAULT_EXTENSIONS = %w[.tsx .jsx].freeze

    def self.scan(dir, extensions: DEFAULT_EXTENSIONS)
      Scanner.scan(dir, extensions: extensions)
    end

    def self.emit(routes:, skipped:, source_dir:, generated_at: nil)
      Emitter.emit(routes: routes, skipped: skipped, source_dir: source_dir, generated_at: generated_at)
    end

    def self.emit_controllers(routes:)
      ControllerEmitter.emit(routes: routes)
    end

    # Scans a directory and classifies each file as a Route or Skipped.
    module Scanner
      class << self
        def scan(dir, extensions: DEFAULT_EXTENSIONS)
          raise ArgumentError, "pages-routes: #{dir.inspect} is not a directory" unless File.directory?(dir)

          routes = []
          skipped = []
          collect_files(dir, extensions).each do |rel_path|
            segments = path_segments(rel_path)
            leaf = segments.last
            if (reason = SKIPPED_LEAVES[leaf])
              skipped << Skipped.new(source_path: rel_path, reason: reason)
            else
              routes << build_route(segments, rel_path)
            end
          end
          [routes, skipped]
        end

        private

        def collect_files(dir, extensions)
          base = Pathname.new(dir)
          Dir.glob(File.join(dir, "**", "*")).filter_map do |abs_path|
            next unless File.file?(abs_path) && extensions.include?(File.extname(abs_path))

            Pathname.new(abs_path).relative_path_from(base).to_s
          end.sort
        end

        def path_segments(rel_path)
          parts = rel_path.split(File::SEPARATOR)
          parts[-1] = parts[-1].sub(/\.[^.]+\z/, "")
          parts
        end

        def build_route(segments, source_path)
          leaf = segments.last
          dir_segments = segments[0..-2]
          inside_bracket_dir = dir_segments.any? { |s| bracket_segment?(s) }

          Route.new(
            rails_path: rails_path_for(segments),
            controller: controller_for(dir_segments),
            action: action_for(leaf, inside_bracket_dir: inside_bracket_dir),
            source_path: source_path
          )
        end

        def action_for(leaf, inside_bracket_dir:)
          return inside_bracket_dir ? "show" : "index" if leaf == "index"
          return "show" if bracket_segment?(leaf)

          AST::Inflector.underscore(leaf)
        end

        def controller_for(dir_segments)
          first_named = dir_segments.find { |segment| !bracket_segment?(segment) }
          AST::Inflector.underscore(first_named || "pages")
        end

        def rails_path_for(segments)
          parts = segments.map { |segment| segment_to_path_part(segment) }
          parts.pop if parts.last == [:literal, "index"]
          build_path(parts)
        end

        def segment_to_path_part(segment)
          case segment
          when /\A\[\[\.\.\.([^\]]+)\]\]\z/
            [:optional_catch_all, AST::Inflector.underscore(Regexp.last_match(1))]
          when /\A\[\.\.\.([^\]]+)\]\z/
            [:catch_all, AST::Inflector.underscore(Regexp.last_match(1))]
          when /\A\[([^\]]+)\]\z/
            [:param, AST::Inflector.underscore(Regexp.last_match(1))]
          else
            [:literal, segment]
          end
        end

        def bracket_segment?(segment)
          segment.start_with?("[") && segment.end_with?("]")
        end

        def build_path(parts)
          return "/" if parts.empty?

          parts.each_with_object(+"") do |(kind, name), result|
            case kind
            when :literal then result << "/#{name}"
            when :param then result << "/:#{name}"
            when :catch_all then result << "/*#{name}"
            when :optional_catch_all then result << "(/*#{name})"
            end
          end
        end
      end
    end

    # Renders a Scanner result as a full `config/routes.rb` file.
    module Emitter
      class << self
        def emit(routes:, skipped:, source_dir:, generated_at: nil)
          generated_at ||= Time.now.utc.strftime("%Y-%m-%d")
          sections = [header(source_dir, generated_at, routes, skipped)]
          sections << skipped_block(skipped) unless skipped.empty?
          sections << draw_block(routes)
          sections << generator_hints(routes) unless routes.empty?
          "#{sections.join("\n\n")}\n"
        end

        private

        def header(source_dir, generated_at, routes, skipped)
          [
            "# frozen_string_literal: true",
            "#",
            "# Generated by jsx_rosetta pages-routes (#{JsxRosetta::VERSION}) from #{source_dir} on #{generated_at}.",
            "# #{routes.size} route(s), #{skipped.size} skipped file(s). Review before committing."
          ].join("\n")
        end

        def skipped_block(skipped)
          lines = ["# Skipped (non-page files — wire up Rails counterparts separately):"]
          skipped.each { |entry| lines << "#   - #{entry.source_path} → #{entry.reason}" }
          lines.join("\n")
        end

        def draw_block(routes)
          return "Rails.application.routes.draw do\nend" if routes.empty?

          unique, duplicates = dedupe(routes)
          body = grouped_body(unique, duplicates)
          (["Rails.application.routes.draw do"] + body + ["end"]).join("\n")
        end

        def dedupe(routes)
          unique = {}
          duplicates = Hash.new { |h, k| h[k] = [] }
          routes.each do |route|
            key = [route.controller, route.action, route.rails_path]
            if unique.key?(key)
              duplicates[key] << route
            else
              unique[key] = route
            end
          end
          [unique.values, duplicates]
        end

        def grouped_body(routes, duplicates)
          by_controller = routes.group_by(&:controller).sort.to_h
          lines = []
          by_controller.each_with_index do |(controller, group_routes), idx|
            lines << "" if idx.positive?
            lines << "  # == #{controller} =="
            group_routes.sort_by { |r| sort_key(r) }.each do |route|
              lines << route_line(route)
              dup_key = [route.controller, route.action, route.rails_path]
              next unless duplicates.key?(dup_key)

              dup_sources = duplicates[dup_key].map(&:source_path).join(", ")
              lines << "  # ↑ also produced by: #{dup_sources}"
            end
          end
          lines
        end

        def sort_key(route)
          # `root to: ...` first within its group, then alpha by path.
          [route.rails_path == "/" ? 0 : 1, route.rails_path]
        end

        def route_line(route)
          if route.rails_path == "/" && route.controller == "pages" && route.action == "index"
            %(  root to: "pages#index")
          elsif route.rails_path.start_with?("*")
            %(  match #{route.rails_path.inspect}, to: "#{route.controller}##{route.action}", via: :all)
          else
            %(  get #{route.rails_path.inspect}, to: "#{route.controller}##{route.action}")
          end
        end

        def generator_hints(routes)
          unique = routes.uniq { |r| [r.controller, r.action] }
          by_controller = unique.group_by(&:controller).sort.to_h
          lines = ["# Suggested controller scaffolds (uncomment to run with `ruby`):"]
          by_controller.each do |controller, group_routes|
            actions = group_routes.map(&:action).uniq.sort
            args = ([controller] + actions).map(&:inspect).join(", ")
            lines << %(# system "rails", "generate", "controller", #{args}, "--skip-routes")
          end
          lines.join("\n")
        end
      end
    end

    # Renders ApplicationController-inheriting skeletons, one per
    # controller in the route table. Each action body is empty; URL
    # params for that action are listed in a comment above the def.
    module ControllerEmitter
      class << self
        def emit(routes:)
          unique = routes.uniq { |r| [r.controller, r.action] }
          unique.group_by(&:controller).sort.map do |controller, group_routes|
            ControllerFile.new(
              path: "#{controller}_controller.rb",
              contents: render(controller, group_routes.sort_by(&:action))
            )
          end
        end

        private

        def render(controller, group_routes)
          class_name = "#{AST::Inflector.upper_camelize(controller)}Controller"
          actions = group_routes.map { |route| action_section(route) }.join("\n\n")
          <<~RUBY
            # frozen_string_literal: true

            # Generated by jsx_rosetta pages-routes. Wire up `before_action`
            # filters and load instance variables for the matching Phlex view
            # (app/views/#{controller}/<action>.rb).
            class #{class_name} < ApplicationController
            #{actions}
            end
          RUBY
        end

        def action_section(route)
          params = route.url_params
          comment = params.empty? ? "" : "  # params: #{params.map { |p| ":#{p}" }.join(", ")}\n"
          "#{comment}  def #{route.action}\n  end"
        end
      end
    end
  end
end
