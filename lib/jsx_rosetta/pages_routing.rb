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
    # A single route resolved from the pages tree.
    #
    # `namespace` is `[]` for top-level routes, otherwise an ordered list of
    # Rails namespace segments (slice-4 B3 nested dirs + B5 route groups).
    # Both shapes flow into the same array — Naming + Emitter wrap routes in
    # nested `namespace :foo do` blocks regardless of which mechanism added
    # the segment.
    #
    # `kind` is `:standard` for regular GET routes, `:error_page` for
    # `_error.tsx` / `404.tsx` / `500.tsx` (emitted via `config.exceptions_app`
    # rather than the regular draw block), or `:layout` for `_app.tsx`
    # (emitted as a view-placement directive only, not a route line).
    Route = Data.define(:rails_path, :controller, :action, :source_path, :namespace, :kind) do
      def initialize(rails_path:, controller:, action:, source_path:, namespace: [], kind: :standard)
        super
      end

      # Extracts the named URL params from `rails_path` in order. Catches
      # `:foo`, `*rest`, and `(/*extra)`-style optional catch-alls.
      def url_params
        return [] if rails_path.nil?

        rails_path.scan(/[:*]([a-z_][a-z0-9_]*)/i).flatten
      end
    end

    Skipped = Data.define(:source_path, :reason)
    ControllerFile = Data.define(:path, :contents)

    SKIPPED_LEAVES = {
      "_document" => "Next.js HTML document — typically subsumed by Rails layout"
    }.freeze

    # Next.js error pages — leaf names that map to an `errors` controller
    # with a standard action name. Routed via `config.exceptions_app` in
    # Rails, not via the regular draw block.
    ERROR_PAGE_LEAVES = {
      "_error" => "fallback",
      "404" => "not_found",
      "500" => "internal_server_error"
    }.freeze

    # Leaf names that resolve to a Rails application layout, not a page.
    # `_app.tsx` lands as `app/views/layouts/<action>.rb`. `_document.tsx`
    # stays in SKIPPED_LEAVES — Rails owns the surrounding HTML scaffold.
    LAYOUT_LEAVES = {
      "_app" => "application"
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

    # Derives Rails route names and URL helper names from a Route. Used
    # by both the routes.rb emitter (slice 1's `as:` lines) and the
    # Phlex backend's href rewriter (slice 3) so the names stay paired.
    module Naming
      module_function

      def route_name(route)
        return "root" if route.rails_path == "/" && route.controller == "pages" &&
                         route.action == "index" && route.namespace.empty?

        base = base_route_name(route)
        return base if route.namespace.empty?

        "#{route.namespace.join("_")}_#{base}"
      end

      def url_helper_name(route)
        "#{route_name(route)}_path"
      end

      def base_route_name(route)
        case route.action
        when "index" then route.controller
        when "show" then AST::Inflector.singularize(route.controller)
        when "new" then "new_#{AST::Inflector.singularize(route.controller)}"
        when "edit" then "edit_#{AST::Inflector.singularize(route.controller)}"
        else "#{route.controller}_#{route.action}"
        end
      end
    end

    # Matches `href`/`to` paths against the route table and emits a
    # Rails URL helper invocation. The caller pre-translates any
    # template-literal hole expressions into Ruby; this class itself
    # does no JS-to-Ruby translation.
    class HrefRewriter
      Token = Data.define(:kind, :value)

      def initialize(routes)
        @routes = routes
      end

      # Try to rewrite a literal path. Returns Ruby source string or nil.
      def rewrite_literal(path)
        return nil unless rewritable_path?(path)

        tokens = path.split("/").reject(&:empty?).map { |seg| Token.new(kind: :literal, value: seg) }
        rewrite_tokens(tokens)
      end

      # Try to rewrite a parsed template literal. `segments` is an array
      # of `[:literal, "..."]` / `[:hole, "ruby_expr"]` pairs — the output
      # of `.parse_template_source` after the caller translates each hole.
      # Returns Ruby source or nil.
      def rewrite_template(segments)
        tokens = template_tokens(segments)
        return nil unless tokens

        rewrite_tokens(tokens)
      end

      # Parse a verbatim JS template literal source like
      # `` `/foo/${bar}` `` into
      # `[[:literal, "/foo/"], [:hole, "bar"], [:literal, ""]]`. Returns
      # nil for malformed input or nested-brace interpolations.
      def self.parse_template_source(js_source)
        return nil unless js_source.is_a?(String) && js_source.start_with?("`") && js_source.end_with?("`")
        return nil if js_source.length < 2

        body = js_source[1..-2]
        return nil if body.include?("`")

        parts = []
        pos = 0
        hole_count = 0
        body.to_enum(:scan, /\$\{([^{}]+)\}/).each do |_|
          match = ::Regexp.last_match
          parts << [:literal, body[pos...match.begin(0)]]
          parts << [:hole, match[1].strip]
          pos = match.end(0)
          hole_count += 1
        end
        parts << [:literal, body[pos..]]
        # `${...}` left in the trailing literal means an interpolation
        # had nested braces and we can't safely match it.
        return nil if body.scan("${").size != hole_count

        parts
      end

      private

      def rewritable_path?(path)
        return false unless path.is_a?(String)
        return false unless path.start_with?("/")
        return false if path.start_with?("//")
        return false if path.include?("?") || path.include?("#")

        true
      end

      # Convert template segments into per-path-segment tokens by
      # joining them with a sentinel marker then splitting on `/`. A
      # hole must occupy a full path segment — `/foo${bar}/baz` fails
      # because `foo${bar}` is a mixed literal+hole segment.
      def template_tokens(segments)
        joined = +""
        holes = []
        segments.each do |kind, value|
          case kind
          when :literal
            return nil if value.include?("?") || value.include?("#")

            joined << value
          when :hole
            joined << "\x01#{holes.length}\x01"
            holes << value
          end
        end
        return nil unless joined.start_with?("/")

        joined.split("/").reject(&:empty?).map do |segment|
          if (m = /\A\x01(\d+)\x01\z/.match(segment))
            Token.new(kind: :hole, value: holes[Integer(m[1])])
          elsif segment.include?("\x01")
            return nil
          else
            Token.new(kind: :literal, value: segment)
          end
        end
      end

      def rewrite_tokens(tokens)
        matches = @routes.filter_map { |route| match_route(route, tokens) }
        return nil if matches.size != 1

        route, ruby_args = matches.first
        helper = Naming.url_helper_name(route)
        ruby_args.empty? ? helper : "#{helper}(#{ruby_args.join(", ")})"
      end

      def match_route(route, tokens)
        route_segments = route.rails_path.split("/").reject(&:empty?)
        return nil if route_segments.any? { |s| s.start_with?("*") || s.start_with?("(") }
        return nil unless route_segments.size == tokens.size

        ruby_args = match_segments(route_segments, tokens)
        ruby_args && [route, ruby_args]
      end

      def match_segments(route_segments, tokens)
        ruby_args = []
        route_segments.zip(tokens).each do |route_seg, token|
          if route_seg.start_with?(":")
            ruby_args << (token.kind == :literal ? literal_arg_to_ruby(token.value) : token.value)
          elsif token.kind == :literal && token.value == route_seg
            next
          else
            return nil
          end
        end
        ruby_args
      end

      def literal_arg_to_ruby(value)
        value.match?(/\A-?\d+\z/) ? value : AST::Inflector.ruby_string_literal(value)
      end
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
            elsif ERROR_PAGE_LEAVES.key?(leaf)
              routes << build_error_route(leaf, rel_path)
            elsif LAYOUT_LEAVES.key?(leaf)
              routes << build_layout_route(leaf, rel_path)
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

        # `_error.tsx` / `404.tsx` / `500.tsx` get a synthetic ErrorsController
        # route. `rails_path` records the URL Rails should match (`/<status>`)
        # so HrefRewriter and emitter share the same shape, but the emitter
        # ignores it for the `get` block (it's listed in the `config.exceptions_app`
        # comment header instead).
        def build_error_route(leaf, source_path)
          action = ERROR_PAGE_LEAVES.fetch(leaf)
          Route.new(
            rails_path: "/#{leaf}",
            controller: "errors",
            action: action,
            source_path: source_path,
            kind: :error_page
          )
        end

        # `_app.tsx` lands as a Rails application layout. It does NOT
        # produce a route line in routes.rb (rails_path is nil) — the
        # emitter calls it out in a dedicated comment block instead.
        # `controller` reads "layouts" so the Phlex view-placement path
        # falls out naturally (`app/views/layouts/application.rb`).
        def build_layout_route(leaf, source_path)
          action = LAYOUT_LEAVES.fetch(leaf)
          Route.new(
            rails_path: nil,
            controller: "layouts",
            action: action,
            source_path: source_path,
            kind: :layout
          )
        end

        def build_route(segments, source_path)
          leaf = segments.last
          dir_segments = segments[0..-2]
          inside_bracket_dir = dir_segments.any? { |s| bracket_segment?(s) }
          controller, namespace = controller_and_namespace_for(dir_segments)

          Route.new(
            rails_path: rails_path_for(segments),
            controller: controller,
            action: action_for(leaf, inside_bracket_dir: inside_bracket_dir),
            source_path: source_path,
            namespace: namespace
          )
        end

        def action_for(leaf, inside_bracket_dir:)
          return inside_bracket_dir ? "show" : "index" if leaf == "index"
          return "show" if bracket_segment?(leaf)

          AST::Inflector.underscore(leaf)
        end

        # Returns [controller_name, namespace_array]. Splits dir_segments
        # into three buckets: route_groups (paren-wrapped) feed entirely
        # into namespace; named dirs feed into namespace except for the
        # last one which becomes the controller; bracket dirs (URL params)
        # are URL-only and don't participate in either.
        def controller_and_namespace_for(dir_segments)
          named = []
          groups = []
          dir_segments.each do |segment|
            if route_group_segment?(segment)
              groups << route_group_name(segment)
            elsif !bracket_segment?(segment)
              named << segment
            end
          end
          controller = named.empty? ? "pages" : named.pop
          namespace = (groups + named).map { |n| AST::Inflector.underscore(n) }
          [AST::Inflector.underscore(controller), namespace]
        end

        def rails_path_for(segments)
          parts = segments.filter_map { |segment| segment_to_path_part(segment) }
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
          when /\A\(([^)]+)\)\z/
            # Route groups are URL-invisible — they only affect controller
            # namespace (handled in controller_and_namespace_for).
            nil
          else
            [:literal, segment]
          end
        end

        def bracket_segment?(segment)
          segment.start_with?("[") && segment.end_with?("]")
        end

        def route_group_segment?(segment)
          segment.start_with?("(") && segment.end_with?(")") && segment.length > 2
        end

        def route_group_name(segment)
          segment[1..-2]
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
          page_routes = routes.select { |r| r.kind == :standard }
          error_routes = routes.select { |r| r.kind == :error_page }
          layout_routes = routes.select { |r| r.kind == :layout }
          sections = [header(source_dir, generated_at, routes, skipped)]
          sections << skipped_block(skipped) unless skipped.empty?
          sections << layouts_block(layout_routes) unless layout_routes.empty?
          sections << error_pages_block(error_routes) unless error_routes.empty?
          sections << draw_block(page_routes, error_routes)
          sections << generator_hints(page_routes) unless page_routes.empty?
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

        # Header for application-layout files (`_app.tsx`). Layouts don't
        # produce route lines — they land in `app/views/layouts/<action>.rb`
        # via the Phlex view-placement path. Listed in the header so a
        # human reading routes.rb can see where _app.tsx went.
        def layouts_block(layout_routes)
          lines = ["# Layouts — translated to app/views/layouts/<action>.rb. " \
                   "No route lines are emitted; Rails resolves layouts by name."]
          layout_routes.sort_by(&:action).each do |route|
            lines << "#   - #{route.source_path} → app/views/layouts/#{route.action}.rb"
          end
          lines.join("\n")
        end

        # Wiring header for error pages. Listed above the draw block since
        # Rails matches these via `config.exceptions_app`, not via the regular
        # router. The comment block names each detected error page + the
        # corresponding ErrorsController action, plus the two standard wiring
        # approaches (exceptions_app vs. public/<status>.html).
        def error_pages_block(error_routes)
          lines = [
            "# Error pages — Next.js _error / 404 / 500 detected. Wire one of:",
            "#",
            "# (1) config.exceptions_app — in config/application.rb:",
            "#       config.exceptions_app = self.routes",
            "#     Then declare them as ordinary routes inside the draw block:"
          ]
          error_routes.sort_by(&:rails_path).each do |route|
            lines << "#       match #{route.rails_path.inspect}, " \
                     "to: \"errors##{route.action}\", via: :all"
          end
          lines += [
            "#",
            "# (2) Static fallbacks — drop the rendered templates at",
            "#     public/404.html / public/500.html and let Rails serve them",
            "#     directly without hitting the app."
          ]
          lines.join("\n")
        end

        def draw_block(routes, error_routes = [])
          return "Rails.application.routes.draw do\nend" if routes.empty? && error_routes.empty?

          unique, duplicates = dedupe(routes)
          body = grouped_body(unique, duplicates)
          body += error_routes_draw_lines(error_routes) unless error_routes.empty?
          (["Rails.application.routes.draw do"] + body + ["end"]).join("\n")
        end

        # The error-page routes themselves still go in the draw block so
        # `match "/404", to: "errors#not_found"` is part of routes.rb — the
        # header comment explains the `config.exceptions_app` wiring needed
        # to make Rails actually invoke them. Sorted with a blank line above
        # for visual separation.
        def error_routes_draw_lines(error_routes)
          lines = ["", "  # == errors (config.exceptions_app) =="]
          error_routes.sort_by(&:action).each do |route|
            lines << (%(  match #{route.rails_path.inspect}, to: "errors##{route.action}", ) +
                     %(via: :all, as: :#{Naming.route_name(route)}))
          end
          lines
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
          by_controller = routes.group_by { |r| group_key(r) }.sort.to_h
          lines = []
          by_controller.each_with_index do |(_, group_routes), idx|
            lines << "" if idx.positive?
            lines << "  # == #{controller_label(group_routes.first)} =="
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

        def group_key(route)
          [route.namespace, route.controller]
        end

        def controller_label(route)
          qualified_controller(route)
        end

        def qualified_controller(route)
          (route.namespace + [route.controller]).join("/")
        end

        def sort_key(route)
          # `root to: ...` first within its group, then alpha by path.
          [route.rails_path == "/" ? 0 : 1, route.rails_path]
        end

        def route_line(route)
          target = qualified_controller(route)
          if route.rails_path == "/" && target == "pages" && route.action == "index"
            %(  root to: "pages#index")
          elsif route.rails_path.start_with?("*")
            %(  match #{route.rails_path.inspect}, to: "#{target}##{route.action}", ) +
              %(via: :all, as: :#{Naming.route_name(route)})
          else
            %(  get #{route.rails_path.inspect}, to: "#{target}##{route.action}", ) +
              %(as: :#{Naming.route_name(route)})
          end
        end

        def generator_hints(routes)
          unique = routes.uniq { |r| [r.namespace, r.controller, r.action] }
          by_controller = unique.group_by { |r| [r.namespace, r.controller] }.sort.to_h
          lines = ["# Suggested controller scaffolds (uncomment to run with `ruby`):"]
          by_controller.each_value do |group_routes|
            target = qualified_controller(group_routes.first)
            actions = group_routes.map(&:action).uniq.sort
            args = ([target] + actions).map(&:inspect).join(", ")
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
          unique = routes.uniq { |r| [r.namespace, r.controller, r.action] }
          unique.group_by { |r| [r.namespace, r.controller] }.sort.map do |(namespace, controller), group_routes|
            ControllerFile.new(
              path: controller_path(namespace, controller),
              contents: render(namespace, controller, group_routes.sort_by(&:action))
            )
          end
        end

        private

        def controller_path(namespace, controller)
          ((namespace || []) + ["#{controller}_controller.rb"]).join("/")
        end

        def render(namespace, controller, group_routes)
          qualified_class = qualified_controller_class(namespace, controller)
          view_dir = ((namespace || []) + [controller]).join("/")
          actions = group_routes.map { |route| action_section(route) }.join("\n\n")
          <<~RUBY
            # frozen_string_literal: true

            # Generated by jsx_rosetta pages-routes. Wire up `before_action`
            # filters and load instance variables for the matching Phlex view
            # (app/views/#{view_dir}/<action>.rb).
            class #{qualified_class} < ApplicationController
            #{actions}
            end
          RUBY
        end

        def qualified_controller_class(namespace, controller)
          parts = (namespace || []).map { |ns| AST::Inflector.upper_camelize(ns) }
          parts << "#{AST::Inflector.upper_camelize(controller)}Controller"
          parts.join("::")
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
