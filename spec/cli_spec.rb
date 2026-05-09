# frozen_string_literal: true

require "stringio"
require "tmpdir"

RSpec.describe JsxRosetta::CLI do
  def run(*argv)
    stdout = StringIO.new
    stderr = StringIO.new
    code = described_class.new(argv, stdout: stdout, stderr: stderr).run
    { code: code, stdout: stdout.string, stderr: stderr.string }
  end

  describe "help" do
    it "prints usage with no arguments" do
      result = run

      expect(result[:code]).to eq(JsxRosetta::CLI::EXIT_OK)
      expect(result[:stdout]).to include("Usage: jsx_rosetta")
      expect(result[:stdout]).to include("translate")
      expect(result[:stdout]).to include("install")
    end

    it "prints usage and a usage exit code on an unknown command" do
      result = run("walks-the-dog")

      expect(result[:code]).to eq(JsxRosetta::CLI::EXIT_USAGE)
      expect(result[:stderr]).to include("unknown command")
    end
  end

  describe "version" do
    it "prints the gem version" do
      result = run("version")

      expect(result[:code]).to eq(JsxRosetta::CLI::EXIT_OK)
      expect(result[:stdout].strip).to eq(JsxRosetta::VERSION)
    end
  end

  describe "translate" do
    it "writes the translated files to the output directory" do
      Dir.mktmpdir do |dir|
        result = run("translate", fixture_path("jsx", "button.jsx"), "-o", dir)

        expect(result[:code]).to eq(JsxRosetta::CLI::EXIT_OK)
        expect(File).to exist(File.join(dir, "button_component.rb"))
        expect(File).to exist(File.join(dir, "button_component.html.erb"))
        expect(result[:stdout]).to include("wrote")
      end
    end

    it "emits a usage error when no file is given" do
      result = run("translate")

      expect(result[:code]).to eq(JsxRosetta::CLI::EXIT_USAGE)
      expect(result[:stderr]).to include("missing required argument")
    end
  end

  describe "parse" do
    it "prints the parsed AST as JSON" do
      result = run("parse", fixture_path("jsx", "button.jsx"))

      expect(result[:code]).to eq(JsxRosetta::CLI::EXIT_OK)
      parsed = JSON.parse(result[:stdout])
      expect(parsed["type"]).to eq("File")
    end
  end
end
