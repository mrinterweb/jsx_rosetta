# frozen_string_literal: true

require "json"
require "open3"

module JsxRosetta
  # Spawns the Node sidecar (`node/parse.js`) as a one-shot subprocess
  # per parse request. A long-lived worker is a future optimization.
  class NodeBridge
    SIDECAR_DIR = File.expand_path("../../node", __dir__)
    SIDECAR_SCRIPT = File.join(SIDECAR_DIR, "parse.js")
    NODE_MODULES_DIR = File.join(SIDECAR_DIR, "node_modules")

    class MissingNode < Error; end
    class MissingDependencies < Error; end

    def parse(source, typescript: false, source_filename: nil)
      ensure_dependencies_installed!

      request = JSON.generate(
        source: source,
        typescript: typescript,
        source_filename: source_filename
      )
      stdout, stderr, status = Open3.capture3(node_executable, SIDECAR_SCRIPT, stdin_data: request)

      raise Error, "jsx_rosetta sidecar exited with status #{status.exitstatus}: #{stderr.strip}" unless status.success?

      JSON.parse(stdout)
    rescue Errno::ENOENT
      raise MissingNode, missing_node_message
    end

    private

    def node_executable
      ENV["JSX_ROSETTA_NODE"] || "node"
    end

    def ensure_dependencies_installed!
      return if File.directory?(File.join(NODE_MODULES_DIR, "@babel", "parser"))

      raise MissingDependencies, <<~MSG.strip
        Node dependencies for jsx_rosetta are not installed.
        Run `bundle exec jsx_rosetta install` (or `cd #{SIDECAR_DIR} && npm install`).
      MSG
    end

    def missing_node_message
      <<~MSG.strip
        Could not find Node.js. jsx_rosetta requires Node.js (>= 18) on PATH,
        or set JSX_ROSETTA_NODE to the absolute path of a node executable.
      MSG
    end
  end
end
