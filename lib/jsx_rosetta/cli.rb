# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "pathname"

require_relative "node_bridge"

module JsxRosetta
  # Command-line interface for the gem.
  #
  # Subcommands:
  #   install                    npm-install the Node sidecar dependencies.
  #   translate FILE [-o DIR]    JSX/TSX → ViewComponent files written to DIR
  #                              (default: current directory). TSX is detected
  #                              via the .tsx extension or --tsx.
  #   parse FILE                 Print the parsed Babel AST as pretty JSON.
  #   pages-routes DIR [-o PATH] Walk a Next.js `pages/` directory and emit a
  #                              Rails config/routes.rb skeleton.
  #   version                    Print the gem version.
  #   help                       Show usage.
  class CLI
    EXIT_OK = 0
    EXIT_USAGE = 64
    EXIT_FAILURE = 1

    USAGE_TEXT = <<~USAGE
      Usage: jsx_rosetta <command> [args]

      Commands:
        install                    Install the gem's Node sidecar dependencies (runs `npm install`).
        translate FILE [-o DIR]    Translate JSX/TSX into ViewComponent files in DIR (default: ".").
                                   Pass --tsx to force TypeScript parsing if the input is .jsx.
                                   Pass --as=view to emit a Rails view template (`<snake>.html.erb`)
                                   instead of a ViewComponent class + sidecar template — appropriate
                                   for pages tied to a route.
                                   Pass --as=phlex to emit a single-file Phlex 2.x view class
                                   (`<snake>.rb`) instead of a ViewComponent. Configure the class
                                   name with --phlex-suffix=Component or --phlex-namespace=Components
                                   (mutually exclusive; default is bare class name).
                                   Pass --rails-routes DIR (with --as=phlex) to place the output
                                   at <controller>/<action>.rb with class
                                   Views::<Controller>::<Action> < Views::Base, derived from a
                                   route table scanned out of DIR (a Next.js pages directory).
        routes FILE [-o OUT.rb]    Parse <Route path=... element={<X/>} /> patterns from FILE
                                   and emit a reviewable Ruby script that calls `rails generate
                                   controller` and prints suggested config/routes.rb additions.
        pages-routes DIR [-o PATH] Walk a Next.js `pages/` directory tree and emit a
                                   Rails config/routes.rb skeleton derived from the file
                                   layout. Use --ext .tsx,.jsx,.ts,.js to override the
                                   default `.tsx,.jsx` filter, and --allow-any-dir to
                                   skip the `basename == 'pages'` safety check.
                                   Pass --controllers DIR to also emit one
                                   `<controller>_controller.rb` per controller in DIR
                                   (existing files are not overwritten).
        parse FILE                 Parse the input and print the Babel AST as JSON.
        version                    Print the gem version.
        help                       Show this help.

      Environment:
        JSX_ROSETTA_NODE           Absolute path to a node executable (default: PATH lookup).
    USAGE

    def initialize(argv = ARGV.dup, stdout: $stdout, stderr: $stderr)
      @argv = argv
      @stdout = stdout
      @stderr = stderr
    end

    def run
      command = @argv.shift
      case command
      when "install" then run_install
      when "translate" then run_translate
      when "routes" then run_routes
      when "pages-routes" then run_pages_routes
      when "parse" then run_parse
      when "version", "-v", "--version" then run_version
      when nil, "help", "-h", "--help" then print_help(EXIT_OK)
      else
        @stderr.puts "jsx_rosetta: unknown command: #{command.inspect}"
        print_help(EXIT_USAGE)
      end
    end

    private

    def run_install
      sidecar_dir = NodeBridge::SIDECAR_DIR
      @stdout.puts "Installing Node sidecar dependencies in #{sidecar_dir}"
      output, status = Open3.capture2e("npm", "install", chdir: sidecar_dir)
      @stdout.print(output)
      status.success? ? EXIT_OK : EXIT_FAILURE
    rescue Errno::ENOENT
      @stderr.puts "jsx_rosetta install: could not find `npm` on PATH. Install Node.js (>= 18) first."
      EXIT_FAILURE
    end

    def run_translate
      options, positional = parse_translate_options
      input_path = positional.first
      return missing_argument("translate FILE", "translate") unless input_path

      resolve_rails_view_route!(options, input_path)

      out_dir = options[:out] || "."
      typescript = options[:tsx] || input_path.end_with?(".tsx")
      backend = backend_for_as(options[:as])
      backend_options = backend_options_for(backend, options)

      source = File.read(input_path)
      files = JsxRosetta.translate(
        source,
        backend: backend,
        backend_options: backend_options,
        typescript: typescript,
        source_filename: input_path
      )

      write_emitted_files(files, out_dir)
      EXIT_OK
    rescue ParseError, IR::Lowering::LoweringError, ArgumentError => e
      @stderr.puts "jsx_rosetta translate: #{e.message}"
      EXIT_FAILURE
    end

    def backend_for_as(value)
      case value
      when "view" then :rails_view
      when "phlex" then :phlex
      else :view_component
      end
    end

    def backend_options_for(backend, options)
      return {} unless backend == :phlex

      base = { suffix: options[:phlex_suffix], namespace: options[:phlex_namespace] }.compact
      base[:rails_view] = options[:rails_view_route] if options[:rails_view_route]
      base
    end

    def resolve_rails_view_route!(options, input_path)
      pages_dir = options[:rails_routes]
      return unless pages_dir

      raise ArgumentError, "--rails-routes requires --as=phlex" unless options[:as] == "phlex"
      if options[:phlex_suffix] || options[:phlex_namespace]
        raise ArgumentError, "--rails-routes cannot be combined with --phlex-suffix or --phlex-namespace"
      end

      ensure_pages_dir!(pages_dir, allow_any: options[:allow_any_dir])
      rel = relative_path_under(input_path, pages_dir)
      raise ArgumentError, "#{input_path} is not under #{pages_dir}" unless rel

      routes, _skipped = PagesRouting.scan(pages_dir, extensions: options[:ext] || PagesRouting::DEFAULT_EXTENSIONS)
      route = routes.find { |r| r.source_path == rel }
      raise ArgumentError, "#{rel} has no route in #{pages_dir} (skipped or non-page file?)" unless route

      options[:rails_view_route] = route
    end

    def relative_path_under(file_path, dir)
      file = Pathname.new(File.expand_path(file_path))
      base = Pathname.new(File.expand_path(dir))
      rel = file.relative_path_from(base).to_s
      rel unless rel.start_with?("..")
    rescue ArgumentError
      nil
    end

    def write_emitted_files(files, out_dir)
      FileUtils.mkdir_p(out_dir)
      files.each do |file|
        target = File.join(out_dir, file.path)
        FileUtils.mkdir_p(File.dirname(target))
        File.write(target, file.contents)
        @stdout.puts "wrote #{target}"
      end
    end

    def run_routes
      options, positional = parse_translate_options
      input_path = positional.first
      return missing_argument("routes FILE [-o OUT.rb]", "routes") unless input_path

      typescript = options[:tsx] || input_path.end_with?(".tsx")
      source = File.read(input_path)
      ast = JsxRosetta.parse(source, typescript: typescript, source_filename: input_path)
      route_tree = Routes.lower(ast)
      script = Backend::RoutesScript.new(source_path: input_path).emit(route_tree)

      if options[:out]
        File.write(options[:out], script)
        @stdout.puts "wrote #{options[:out]}"
      else
        @stdout.print(script)
      end
      EXIT_OK
    rescue ParseError => e
      @stderr.puts "jsx_rosetta routes: #{e.message}"
      EXIT_FAILURE
    end

    def run_pages_routes
      options, positional = parse_translate_options
      input_dir = positional.first
      return missing_argument("pages-routes DIR [-o OUT.rb]", "pages-routes") unless input_dir

      ensure_pages_dir!(input_dir, allow_any: options[:allow_any_dir])
      extensions = options[:ext] || PagesRouting::DEFAULT_EXTENSIONS
      routes, skipped = PagesRouting.scan(input_dir, extensions: extensions)
      contents = PagesRouting.emit(routes: routes, skipped: skipped, source_dir: input_dir)

      if options[:out]
        File.write(options[:out], contents)
        @stdout.puts "wrote #{options[:out]}"
      else
        @stdout.print(contents)
      end

      write_controllers(routes, options[:controllers]) if options[:controllers]
      EXIT_OK
    rescue ArgumentError => e
      @stderr.puts "jsx_rosetta pages-routes: #{e.message}"
      EXIT_FAILURE
    end

    def write_controllers(routes, dir)
      FileUtils.mkdir_p(dir)
      PagesRouting.emit_controllers(routes: routes).each do |file|
        target = File.join(dir, file.path)
        if File.exist?(target)
          @stdout.puts "skipped #{target} (exists)"
        else
          File.write(target, file.contents)
          @stdout.puts "wrote #{target}"
        end
      end
    end

    def ensure_pages_dir!(dir, allow_any:)
      return if allow_any
      return if File.basename(dir) == "pages"
      return if File.directory?(File.join(dir, "pages"))

      raise ArgumentError,
            "#{dir.inspect} does not look like a Next.js pages directory " \
            "(basename != 'pages' and no nested 'pages/'). Pass --allow-any-dir to override."
    end

    def run_parse
      options, positional = parse_translate_options
      input_path = positional.first
      return missing_argument("parse FILE", "parse") unless input_path

      typescript = options[:tsx] || input_path.end_with?(".tsx")

      source = File.read(input_path)
      ast = JsxRosetta.parse(source, typescript: typescript, source_filename: input_path)

      @stdout.puts JSON.pretty_generate(ast.raw)
      EXIT_OK
    rescue ParseError => e
      @stderr.puts "jsx_rosetta parse: #{e.message}"
      EXIT_FAILURE
    end

    def run_version
      @stdout.puts JsxRosetta::VERSION
      EXIT_OK
    end

    def parse_translate_options
      options = {}
      positional = []

      until @argv.empty?
        arg = @argv.shift
        positional << arg unless option_consumed?(arg, options)
      end

      [options, positional]
    end

    def option_consumed?(arg, options)
      consume_translate_option?(arg, options) ||
        consume_phlex_option?(arg, options) ||
        consume_pages_routes_option?(arg, options)
    end

    def consume_translate_option?(arg, options)
      case arg
      when "-o", "--out" then options[:out] = @argv.shift
      when "--tsx", "--typescript" then options[:tsx] = true
      when "--as" then options[:as] = @argv.shift
      when /\A--as=(.+)\z/ then options[:as] = ::Regexp.last_match(1)
      else return false
      end
      true
    end

    def consume_phlex_option?(arg, options)
      case arg
      when "--phlex-suffix" then options[:phlex_suffix] = @argv.shift
      when /\A--phlex-suffix=(.*)\z/ then options[:phlex_suffix] = ::Regexp.last_match(1)
      when "--phlex-namespace" then options[:phlex_namespace] = @argv.shift
      when /\A--phlex-namespace=(.+)\z/ then options[:phlex_namespace] = ::Regexp.last_match(1)
      when "--rails-routes" then options[:rails_routes] = @argv.shift
      when /\A--rails-routes=(.+)\z/ then options[:rails_routes] = ::Regexp.last_match(1)
      else return false
      end
      true
    end

    def consume_pages_routes_option?(arg, options)
      case arg
      when "--ext" then options[:ext] = parse_ext_list(@argv.shift)
      when /\A--ext=(.+)\z/ then options[:ext] = parse_ext_list(::Regexp.last_match(1))
      when "--allow-any-dir" then options[:allow_any_dir] = true
      when "--controllers" then options[:controllers] = @argv.shift
      when /\A--controllers=(.+)\z/ then options[:controllers] = ::Regexp.last_match(1)
      else return false
      end
      true
    end

    def parse_ext_list(value)
      value.to_s.split(",").map(&:strip).reject(&:empty?).map { |ext| ext.start_with?(".") ? ext : ".#{ext}" }
    end

    def missing_argument(usage, command)
      @stderr.puts "jsx_rosetta #{command}: missing required argument."
      @stderr.puts "  usage: jsx_rosetta #{usage}"
      EXIT_USAGE
    end

    def print_help(exit_code)
      @stdout.puts USAGE_TEXT
      exit_code
    end
  end
end
