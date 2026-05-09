# frozen_string_literal: true

require_relative "lib/jsx_rosetta/version"

Gem::Specification.new do |spec|
  spec.name = "jsx_rosetta"
  spec.version = JsxRosetta::VERSION
  spec.authors = ["Sean McCleary"]
  spec.email = ["seanmcc@gmail.com"]

  spec.summary = "Translate JSX components into Rails ViewComponent (Ruby class + ERB template)."
  spec.description = <<~DESC
    jsx_rosetta is a JSX-to-Rails translator. It parses JSX via Babel
    (over a Node sidecar), lowers the parsed AST into a framework-agnostic
    semantic IR, and emits target output via pluggable backends. The
    initial backend produces ViewComponent classes paired with ERB
    templates; additional backends (Phlex, Slim, Phoenix LiveView, etc.)
    can be added against the same IR.
  DESC
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore .rspec spec/ .github/ .rubocop.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
  spec.metadata["rubygems_mfa_required"] = "true"
end
