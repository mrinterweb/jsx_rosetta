# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"

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
  #   version                    Print the gem version.
  #   help                       Show usage.
  class CLI
    EXIT_OK = 0
    EXIT_USAGE = 64
    EXIT_FAILURE = 1

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

      out_dir = options[:out] || "."
      typescript = options[:tsx] || input_path.end_with?(".tsx")
      backend = options[:as] == "view" ? :rails_view : :view_component

      source = File.read(input_path)
      files = JsxRosetta.translate(
        source,
        backend: backend,
        typescript: typescript,
        source_filename: input_path
      )

      FileUtils.mkdir_p(out_dir)
      files.each do |file|
        target = File.join(out_dir, file.path)
        FileUtils.mkdir_p(File.dirname(target))
        File.write(target, file.contents)
        @stdout.puts "wrote #{target}"
      end
      EXIT_OK
    rescue ParseError, IR::Lowering::LoweringError => e
      @stderr.puts "jsx_rosetta translate: #{e.message}"
      EXIT_FAILURE
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
        case arg
        when "-o", "--out" then options[:out] = @argv.shift
        when "--tsx", "--typescript" then options[:tsx] = true
        when "--as" then options[:as] = @argv.shift
        when /\A--as=(.+)\z/ then options[:as] = ::Regexp.last_match(1)
        else positional << arg
        end
      end

      [options, positional]
    end

    def missing_argument(usage, command)
      @stderr.puts "jsx_rosetta #{command}: missing required argument."
      @stderr.puts "  usage: jsx_rosetta #{usage}"
      EXIT_USAGE
    end

    def print_help(exit_code)
      @stdout.puts <<~USAGE
        Usage: jsx_rosetta <command> [args]

        Commands:
          install                    Install the gem's Node sidecar dependencies (runs `npm install`).
          translate FILE [-o DIR]    Translate JSX/TSX into ViewComponent files in DIR (default: ".").
                                     Pass --tsx to force TypeScript parsing if the input is .jsx.
                                     Pass --as=view to emit a Rails view template (`<snake>.html.erb`)
                                     instead of a ViewComponent class + sidecar template — appropriate
                                     for pages tied to a route.
          routes FILE [-o OUT.rb]    Parse <Route path=... element={<X/>} /> patterns from FILE
                                     and emit a reviewable Ruby script that calls `rails generate
                                     controller` and prints suggested config/routes.rb additions.
          parse FILE                 Parse the input and print the Babel AST as JSON.
          version                    Print the gem version.
          help                       Show this help.

        Environment:
          JSX_ROSETTA_NODE           Absolute path to a node executable (default: PATH lookup).
      USAGE
      exit_code
    end
  end
end
