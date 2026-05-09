# frozen_string_literal: true

require "jsx_rosetta"

module FixtureHelpers
  FIXTURES_ROOT = File.expand_path("fixtures", __dir__)

  def fixture_path(*parts)
    File.join(FIXTURES_ROOT, *parts)
  end

  def fixture(*parts)
    File.read(fixture_path(*parts))
  end
end

module AstHelpers
  # Walks a parsed Babel AST hash and returns the first descendant node
  # with the given `type`, or nil.
  def find_first_node(node, type) # rubocop:disable Metrics/CyclomaticComplexity
    return node if node.is_a?(Hash) && node["type"] == type

    children =
      case node
      when Hash then node.each_value
      when Array then node
      end
    return nil unless children

    children.each do |child|
      found = find_first_node(child, type)
      return found if found
    end
    nil
  end
end

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.include FixtureHelpers
  config.include AstHelpers
end
