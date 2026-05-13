# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tempfile"
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
    it "writes the translated files to the output directory (sidecar layout)" do
      Dir.mktmpdir do |dir|
        result = run("translate", fixture_path("jsx", "button.jsx"), "-o", dir)

        expect(result[:code]).to eq(JsxRosetta::CLI::EXIT_OK)
        expect(File).to exist(File.join(dir, "button_component.rb"))
        expect(File).to exist(File.join(dir, "button_component", "button_component.html.erb"))
        expect(result[:stdout]).to include("wrote")
      end
    end

    it "emits a usage error when no file is given" do
      result = run("translate")

      expect(result[:code]).to eq(JsxRosetta::CLI::EXIT_USAGE)
      expect(result[:stderr]).to include("missing required argument")
    end

    it "emits a Rails view (no .rb, no sidecar) when --as=view is passed" do
      Dir.mktmpdir do |dir|
        Tempfile.create(["home", ".tsx"]) do |f|
          f.write("export function Home() { return <h1>Welcome</h1>; }")
          f.flush

          result = run("translate", f.path, "--as=view", "-o", dir)

          expect(result[:code]).to eq(JsxRosetta::CLI::EXIT_OK)
          expect(File).to exist(File.join(dir, "home.html.erb"))
          expect(File).not_to exist(File.join(dir, "home_component.rb"))
          expect(File).not_to exist(File.join(dir, "home_component"))
        end
      end
    end
  end

  describe "routes" do
    it "writes a Ruby script when -o is passed" do
      Dir.mktmpdir do |dir|
        Tempfile.create(["routes", ".tsx"]) do |f|
          f.write('function App() { return <Routes><Route path="/" element={<Home />} /></Routes>; }')
          f.flush

          output_path = File.join(dir, "generate_controllers.rb")
          result = run("routes", f.path, "-o", output_path)

          expect(result[:code]).to eq(JsxRosetta::CLI::EXIT_OK)
          expect(File).to exist(output_path)
          expect(File.read(output_path)).to include("Home")
        end
      end
    end

    it "prints to stdout when -o is omitted" do
      Tempfile.create(["routes", ".tsx"]) do |f|
        f.write('function App() { return <Route path="/posts" element={<PostsIndex />} />; }')
        f.flush

        result = run("routes", f.path)

        expect(result[:code]).to eq(JsxRosetta::CLI::EXIT_OK)
        expect(result[:stdout]).to include("PostsIndex")
        expect(result[:stdout]).to include("#!/usr/bin/env ruby")
      end
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

  describe "pages-routes" do
    def make_pages_dir(*relative_paths)
      dir = Dir.mktmpdir("pages_routes_cli")
      pages_dir = File.join(dir, "pages")
      relative_paths.each do |rel|
        full = File.join(pages_dir, rel)
        FileUtils.mkdir_p(File.dirname(full))
        FileUtils.touch(full)
      end
      [dir, pages_dir]
    end

    it "prints a routes.rb skeleton to stdout when -o is omitted" do
      root, pages_dir = make_pages_dir("index.tsx", "accounts/index.tsx", "accounts/[id].tsx")

      result = run("pages-routes", pages_dir)

      expect(result[:code]).to eq(JsxRosetta::CLI::EXIT_OK)
      expect(result[:stdout]).to include("Rails.application.routes.draw do")
      expect(result[:stdout]).to include('root to: "pages#index"')
      expect(result[:stdout]).to include('get "/accounts", to: "accounts#index"')
      expect(result[:stdout]).to include('get "/accounts/:id", to: "accounts#show"')
    ensure
      FileUtils.remove_entry(root) if root
    end

    it "writes the routes.rb when -o is passed" do
      root, pages_dir = make_pages_dir("index.tsx")
      out_path = File.join(root, "routes.rb")

      result = run("pages-routes", pages_dir, "-o", out_path)

      expect(result[:code]).to eq(JsxRosetta::CLI::EXIT_OK)
      expect(File).to exist(out_path)
      expect(File.read(out_path)).to include('root to: "pages#index"')
      expect(result[:stdout]).to include("wrote")
    ensure
      FileUtils.remove_entry(root) if root
    end

    it "refuses a directory not named 'pages' without --allow-any-dir" do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, "index.tsx"))
        result = run("pages-routes", dir)

        expect(result[:code]).to eq(JsxRosetta::CLI::EXIT_FAILURE)
        expect(result[:stderr]).to include("does not look like a Next.js pages directory")
      end
    end

    it "accepts a non-pages directory when --allow-any-dir is passed" do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, "index.tsx"))
        result = run("pages-routes", dir, "--allow-any-dir")

        expect(result[:code]).to eq(JsxRosetta::CLI::EXIT_OK)
        expect(result[:stdout]).to include('root to: "pages#index"')
      end
    end

    it "respects --ext to override the default extension filter" do
      root, pages_dir = make_pages_dir("index.rb", "about.rb")
      result = run("pages-routes", pages_dir, "--ext", ".rb")

      expect(result[:code]).to eq(JsxRosetta::CLI::EXIT_OK)
      expect(result[:stdout]).to include('root to: "pages#index"')
      expect(result[:stdout]).to include('get "/about"')
    ensure
      FileUtils.remove_entry(root) if root
    end

    it "emits a usage error when no directory is given" do
      result = run("pages-routes")

      expect(result[:code]).to eq(JsxRosetta::CLI::EXIT_USAGE)
      expect(result[:stderr]).to include("missing required argument")
    end
  end
end
