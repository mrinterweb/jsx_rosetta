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

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.include FixtureHelpers
end
