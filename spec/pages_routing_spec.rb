# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe JsxRosetta::PagesRouting do
  def build_pages(*relative_paths)
    dir = Dir.mktmpdir("pages_routing")
    relative_paths.each do |rel|
      full = File.join(dir, rel)
      FileUtils.mkdir_p(File.dirname(full))
      FileUtils.touch(full)
    end
    dir
  end

  def scan(*relative_paths, **options)
    dir = build_pages(*relative_paths)
    described_class.scan(dir, **options)
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  def routes_for(*relative_paths, **options)
    scan(*relative_paths, **options).first
  end

  def skipped_for(*relative_paths, **options)
    scan(*relative_paths, **options).last
  end

  describe ".scan classification" do
    it "maps a top-level index.tsx to root → pages#index" do
      routes = routes_for("index.tsx")

      expect(routes.size).to eq(1)
      expect(routes.first).to have_attributes(rails_path: "/", controller: "pages", action: "index")
    end

    it "maps a top-level named file to pages#<name>" do
      route = routes_for("about.tsx").first

      expect(route).to have_attributes(rails_path: "/about", controller: "pages", action: "about")
    end

    it "maps <res>/index.tsx to <res>#index" do
      route = routes_for("accounts/index.tsx").first

      expect(route).to have_attributes(rails_path: "/accounts", controller: "accounts", action: "index")
    end

    it "maps <res>/new.tsx to <res>#new" do
      route = routes_for("accounts/new.tsx").first

      expect(route).to have_attributes(rails_path: "/accounts/new", controller: "accounts", action: "new")
    end

    it "maps <res>/[id].tsx to <res>#show" do
      route = routes_for("accounts/[id].tsx").first

      expect(route).to have_attributes(rails_path: "/accounts/:id", controller: "accounts", action: "show")
    end

    it "maps <res>/[id]/index.tsx to <res>#show (duplicate of [id].tsx form)" do
      route = routes_for("accounts/[id]/index.tsx").first

      expect(route).to have_attributes(rails_path: "/accounts/:id", controller: "accounts", action: "show")
    end

    it "maps <res>/[id]/edit.tsx to <res>#edit" do
      route = routes_for("accounts/[id]/edit.tsx").first

      expect(route).to have_attributes(rails_path: "/accounts/:id/edit", controller: "accounts", action: "edit")
    end

    it "maps <res>/[id]/<x>.tsx to <res>#<x>" do
      route = routes_for("accounts/[id]/settings.tsx").first

      expect(route).to have_attributes(rails_path: "/accounts/:id/settings", controller: "accounts",
                                       action: "settings")
    end

    it "maps optional catch-all [[...extra]].tsx to (/*extra) with show action" do
      route = routes_for("accounts/[id]/[[...extra]].tsx").first

      expect(route).to have_attributes(
        rails_path: "/accounts/:id(/*extra)",
        controller: "accounts",
        action: "show"
      )
    end

    it "maps non-optional rest catch-all [...rest].tsx to *rest" do
      route = routes_for("docs/[...rest].tsx").first

      expect(route).to have_attributes(rails_path: "/docs/*rest", controller: "docs", action: "show")
    end

    it "snake_cases camelCase bracket params" do
      route = routes_for("policies/[providerSlug]/[policyId]/edit.tsx").first

      expect(route.rails_path).to eq("/policies/:provider_slug/:policy_id/edit")
      expect(route.controller).to eq("policies")
      expect(route.action).to eq("edit")
    end

    it "promotes the innermost named dir to controller and outer dirs to namespace (B3)" do
      route = routes_for("workflows/[id]/versions/index.tsx").first

      expect(route).to have_attributes(
        rails_path: "/workflows/:id/versions",
        controller: "versions",
        action: "show",
        namespace: ["workflows"]
      )
    end

    it "snake_cases the action name when the leaf is camelCase" do
      route = routes_for("workflows/[id]/runHistory.tsx").first

      expect(route.action).to eq("run_history")
    end
  end

  describe ".scan namespace nesting (B3)" do
    it "promotes a single named-dir to controller with empty namespace" do
      route = routes_for("users/[id].tsx").first

      expect(route).to have_attributes(
        rails_path: "/users/:id",
        controller: "users",
        action: "show",
        namespace: []
      )
    end

    it "treats two named dirs as namespace + controller" do
      route = routes_for("admin/users/[id].tsx").first

      expect(route).to have_attributes(
        rails_path: "/admin/users/:id",
        controller: "users",
        action: "show",
        namespace: ["admin"]
      )
    end

    it "treats three named dirs as two-level namespace + controller" do
      route = routes_for("admin/billing/invoices/index.tsx").first

      expect(route).to have_attributes(
        rails_path: "/admin/billing/invoices",
        controller: "invoices",
        action: "index",
        namespace: %w[admin billing]
      )
    end

    it "snake_cases multi-word namespace segments" do
      route = routes_for("policyAdmin/users/index.tsx").first

      expect(route.namespace).to eq(["policy_admin"])
      expect(route.controller).to eq("users")
    end

    it "keeps bracket dirs flowing into the URL without breaking namespacing" do
      route = routes_for("admin/users/[id]/edit.tsx").first

      expect(route).to have_attributes(
        rails_path: "/admin/users/:id/edit",
        controller: "users",
        action: "edit",
        namespace: ["admin"]
      )
    end
  end

  describe ".scan route groups (B5)" do
    it "treats a (group) dir as URL-invisible namespace" do
      route = routes_for("(marketing)/about.tsx").first

      expect(route).to have_attributes(
        rails_path: "/about",
        controller: "pages",
        action: "about",
        namespace: ["marketing"]
      )
    end

    it "treats a (group)/index.tsx as URL-invisible root-of-group" do
      route = routes_for("(marketing)/index.tsx").first

      expect(route).to have_attributes(
        rails_path: "/",
        controller: "pages",
        action: "index",
        namespace: ["marketing"]
      )
    end

    it "stacks multiple nested groups" do
      route = routes_for("(marketing)/(public)/about.tsx").first

      expect(route).to have_attributes(
        rails_path: "/about",
        namespace: %w[marketing public]
      )
    end

    it "combines a (group) with a nested named dir (B5 + B3)" do
      route = routes_for("(group)/users/[id].tsx").first

      expect(route).to have_attributes(
        rails_path: "/users/:id",
        controller: "users",
        action: "show",
        namespace: ["group"]
      )
    end

    it "doesn't add the group name to the URL" do
      route = routes_for("(internal)/dashboard.tsx").first

      expect(route.rails_path).to eq("/dashboard")
      expect(route.rails_path).not_to include("internal")
    end
  end

  describe ".scan skipped files" do
    it "skips _document.tsx (HTML scaffolding is owned by Rails)" do
      _routes, skipped = scan("_document.tsx", "index.tsx")

      expect(skipped.map(&:source_path)).to include("_document.tsx")
      expect(skipped.first.reason).to include("HTML document")
    end

    it "produces no standard routes when only layout / skipped files are present" do
      routes, skipped = scan("_app.tsx", "_document.tsx")

      expect(routes.map(&:kind)).to eq([:layout])
      expect(skipped.size).to eq(1)
    end
  end

  describe ".scan layouts (B2)" do
    it "recognizes _app.tsx as a Rails application layout" do
      routes, _skipped = scan("_app.tsx", "index.tsx")
      layout = routes.find { |r| r.kind == :layout }

      expect(layout).to have_attributes(
        rails_path: nil,
        controller: "layouts",
        action: "application",
        source_path: "_app.tsx"
      )
    end

    it "still skips _document.tsx" do
      routes, skipped = scan("_document.tsx", "index.tsx")

      expect(routes.map(&:kind)).not_to include(:layout)
      expect(skipped.map(&:source_path)).to include("_document.tsx")
    end
  end

  describe ".scan error pages (B4)" do
    it "recognizes _error.tsx as a fallback error route" do
      routes, _skipped = scan("_error.tsx", "index.tsx")
      error_route = routes.find { |r| r.kind == :error_page }

      expect(error_route).to have_attributes(
        rails_path: "/_error",
        controller: "errors",
        action: "fallback",
        kind: :error_page
      )
    end

    it "recognizes 404.tsx as not_found" do
      routes, _skipped = scan("404.tsx", "index.tsx")
      error_route = routes.find { |r| r.kind == :error_page }

      expect(error_route).to have_attributes(
        rails_path: "/404",
        controller: "errors",
        action: "not_found"
      )
    end

    it "recognizes 500.tsx as internal_server_error" do
      routes, _skipped = scan("500.tsx", "index.tsx")
      error_route = routes.find { |r| r.kind == :error_page }

      expect(error_route).to have_attributes(
        rails_path: "/500",
        controller: "errors",
        action: "internal_server_error"
      )
    end

    it "does not list error pages as skipped" do
      _routes, skipped = scan("404.tsx", "500.tsx", "_error.tsx")

      expect(skipped.map(&:source_path)).to be_empty
    end
  end

  describe ".scan tree behavior" do
    it "ignores files whose extension is not in the configured list" do
      routes, _skipped = scan("index.tsx", "README.md", "schema.graphql")

      expect(routes.size).to eq(1)
    end

    it "accepts a custom extension list" do
      routes, _skipped = scan("home/index.rb", "about.rb", extensions: %w[.rb])

      expect(routes.map(&:rails_path)).to contain_exactly("/home", "/about")
    end

    it "raises ArgumentError when the directory does not exist" do
      expect { described_class.scan("/nope/does/not/exist") }.to raise_error(ArgumentError, /not a directory/)
    end

    it "returns empty arrays for an empty directory" do
      Dir.mktmpdir do |dir|
        routes, skipped = described_class.scan(dir)
        expect(routes).to be_empty
        expect(skipped).to be_empty
      end
    end
  end

  describe ".emit" do
    let(:route_index) do
      JsxRosetta::PagesRouting::Route.new(
        rails_path: "/", controller: "pages", action: "index", source_path: "index.tsx"
      )
    end

    let(:route_about) do
      JsxRosetta::PagesRouting::Route.new(
        rails_path: "/about", controller: "pages", action: "about", source_path: "about.tsx"
      )
    end

    let(:route_accounts_index) do
      JsxRosetta::PagesRouting::Route.new(
        rails_path: "/accounts", controller: "accounts", action: "index", source_path: "accounts/index.tsx"
      )
    end

    let(:route_accounts_show) do
      JsxRosetta::PagesRouting::Route.new(
        rails_path: "/accounts/:id", controller: "accounts", action: "show", source_path: "accounts/[id].tsx"
      )
    end

    it "produces parseable Ruby for an empty route set" do
      output = described_class.emit(routes: [], skipped: [], source_dir: "pages", generated_at: "2026-05-13")

      expect(output).to include("Rails.application.routes.draw do")
      expect(output).to include("end")
      expect { compile_ruby(output) }.not_to raise_error
    end

    it "emits `root to: \"pages#index\"` for the root index" do
      output = described_class.emit(routes: [route_index], skipped: [], source_dir: "pages",
                                    generated_at: "2026-05-13")

      expect(output).to include(%(  root to: "pages#index"))
      expect(output).not_to include(%(get "/"))
    end

    it "groups routes by controller and alphabetizes the groups" do
      routes = [route_accounts_show, route_accounts_index, route_about, route_index]
      output = described_class.emit(routes: routes, skipped: [], source_dir: "pages", generated_at: "2026-05-13")

      accounts_idx = output.index("# == accounts ==")
      pages_idx = output.index("# == pages ==")
      expect(accounts_idx).to be < pages_idx
      expect(output).to include(%(  get "/accounts", to: "accounts#index"))
      expect(output).to include(%(  get "/accounts/:id", to: "accounts#show"))
      expect(output).to include(%(  get "/about", to: "pages#about"))
      expect(output).to include(%(  root to: "pages#index"))
    end

    it "warns about duplicate routes from multiple source files" do
      dup = JsxRosetta::PagesRouting::Route.new(
        rails_path: "/accounts/:id", controller: "accounts", action: "show",
        source_path: "accounts/[id]/index.tsx"
      )
      output = described_class.emit(
        routes: [route_accounts_show, dup], skipped: [], source_dir: "pages", generated_at: "2026-05-13"
      )

      expect(output.scan(%(  get "/accounts/:id"))).to eq([%(  get "/accounts/:id")])
      expect(output).to include("also produced by: accounts/[id]/index.tsx")
    end

    it "lists skipped files in a comment block above the draw" do
      skipped = [
        JsxRosetta::PagesRouting::Skipped.new(source_path: "_app.tsx", reason: "Next.js application wrapper"),
        JsxRosetta::PagesRouting::Skipped.new(source_path: "404.tsx", reason: "404 page")
      ]
      output = described_class.emit(routes: [route_index], skipped: skipped, source_dir: "pages",
                                    generated_at: "2026-05-13")

      skipped_idx = output.index("# Skipped")
      draw_idx = output.index("Rails.application.routes.draw")
      expect(skipped_idx).to be < draw_idx
      expect(output).to include("#   - _app.tsx → Next.js application wrapper")
      expect(output).to include("#   - 404.tsx → 404 page")
    end

    it "emits `as: :<route-name>` on get/match lines (omitted for root)" do
      output = described_class.emit(
        routes: [route_index, route_about, route_accounts_index, route_accounts_show],
        skipped: [], source_dir: "pages", generated_at: "2026-05-13"
      )

      expect(output).to include('root to: "pages#index"')
      expect(output).not_to match(/root to: "pages#index", as:/)
      expect(output).to include('get "/about", to: "pages#about", as: :pages_about')
      expect(output).to include('get "/accounts", to: "accounts#index", as: :accounts')
      expect(output).to include('get "/accounts/:id", to: "accounts#show", as: :account')
    end

    it "emits a commented controller-scaffold hint per controller" do
      output = described_class.emit(
        routes: [route_index, route_about, route_accounts_index, route_accounts_show],
        skipped: [], source_dir: "pages", generated_at: "2026-05-13"
      )

      expect(output).to include('# system "rails", "generate", "controller", "accounts", "index", "show"')
      expect(output).to include('# system "rails", "generate", "controller", "pages", "about", "index"')
    end

    it "produces a routes.rb that passes ruby -c" do
      output = described_class.emit(
        routes: [route_index, route_about, route_accounts_index, route_accounts_show],
        skipped: [], source_dir: "pages", generated_at: "2026-05-13"
      )

      expect { compile_ruby(output) }.not_to raise_error
    end

    context "namespace nesting (B3 / B5)" do
      let(:route_admin_users_show) do
        JsxRosetta::PagesRouting::Route.new(
          rails_path: "/admin/users/:id", controller: "users", action: "show",
          source_path: "admin/users/[id].tsx", namespace: ["admin"]
        )
      end

      let(:route_admin_users_index) do
        JsxRosetta::PagesRouting::Route.new(
          rails_path: "/admin/users", controller: "users", action: "index",
          source_path: "admin/users/index.tsx", namespace: ["admin"]
        )
      end

      let(:route_marketing_about) do
        JsxRosetta::PagesRouting::Route.new(
          rails_path: "/about", controller: "pages", action: "about",
          source_path: "(marketing)/about.tsx", namespace: ["marketing"]
        )
      end

      it "emits to: \"namespace/controller#action\" form for nested-dir routes" do
        output = described_class.emit(
          routes: [route_admin_users_index, route_admin_users_show], skipped: [],
          source_dir: "pages", generated_at: "2026-05-13"
        )

        expect(output).to include(%(  get "/admin/users", to: "admin/users#index", as: :admin_users))
        expect(output).to include(%(  get "/admin/users/:id", to: "admin/users#show", as: :admin_user))
      end

      it "emits to: \"group/controller#action\" form for route-group routes (B5)" do
        output = described_class.emit(
          routes: [route_marketing_about], skipped: [],
          source_dir: "pages", generated_at: "2026-05-13"
        )

        expect(output).to include(%(  get "/about", to: "marketing/pages#about", as: :marketing_pages_about))
      end

      it "shows the qualified controller in the group-header comment" do
        output = described_class.emit(
          routes: [route_admin_users_index], skipped: [],
          source_dir: "pages", generated_at: "2026-05-13"
        )

        expect(output).to include("# == admin/users ==")
      end

      it "emits the qualified target in the scaffold hint" do
        output = described_class.emit(
          routes: [route_admin_users_index, route_admin_users_show], skipped: [],
          source_dir: "pages", generated_at: "2026-05-13"
        )

        expect(output).to include(
          '# system "rails", "generate", "controller", "admin/users", "index", "show"'
        )
      end

      it "passes ruby -c with namespaced routes" do
        output = described_class.emit(
          routes: [route_admin_users_index, route_admin_users_show, route_marketing_about],
          skipped: [], source_dir: "pages", generated_at: "2026-05-13"
        )

        expect { compile_ruby(output) }.not_to raise_error
      end
    end

    context "error pages (B4)" do
      let(:route_not_found) do
        JsxRosetta::PagesRouting::Route.new(
          rails_path: "/404", controller: "errors", action: "not_found",
          source_path: "404.tsx", kind: :error_page
        )
      end

      let(:route_server_error) do
        JsxRosetta::PagesRouting::Route.new(
          rails_path: "/500", controller: "errors", action: "internal_server_error",
          source_path: "500.tsx", kind: :error_page
        )
      end

      it "emits a config.exceptions_app comment block above the draw" do
        output = described_class.emit(
          routes: [route_index, route_not_found, route_server_error], skipped: [],
          source_dir: "pages", generated_at: "2026-05-13"
        )

        expect(output).to include("# Error pages — Next.js _error / 404 / 500 detected")
        expect(output).to include("config.exceptions_app = self.routes")
        expect(output).to include(%(#       match "/404", to: "errors#not_found", via: :all))
        expect(output).to include(%(#       match "/500", to: "errors#internal_server_error", via: :all))
        expect(output).to include("public/404.html / public/500.html")
      end

      it "lists error routes in a dedicated draw-block section" do
        output = described_class.emit(
          routes: [route_index, route_not_found, route_server_error], skipped: [],
          source_dir: "pages", generated_at: "2026-05-13"
        )

        expect(output).to include("# == errors (config.exceptions_app) ==")
        expect(output).to include(%(  match "/404", to: "errors#not_found", via: :all, as: :errors_not_found))
        expect(output).to include(
          %(  match "/500", to: "errors#internal_server_error", via: :all, as: :errors_internal_server_error)
        )
      end

      it "skips error routes from the standard `# ==` group headers" do
        output = described_class.emit(
          routes: [route_index, route_not_found], skipped: [],
          source_dir: "pages", generated_at: "2026-05-13"
        )

        standard_errors_idx = output.index(%(# == errors ==\n))
        expect(standard_errors_idx).to be_nil
      end

      it "passes ruby -c when error pages are present" do
        output = described_class.emit(
          routes: [route_index, route_not_found, route_server_error], skipped: [],
          source_dir: "pages", generated_at: "2026-05-13"
        )

        expect { compile_ruby(output) }.not_to raise_error
      end
    end

    context "layouts (B2)" do
      let(:route_app_layout) do
        JsxRosetta::PagesRouting::Route.new(
          rails_path: nil, controller: "layouts", action: "application",
          source_path: "_app.tsx", kind: :layout
        )
      end

      it "emits a layouts comment block above the draw" do
        output = described_class.emit(
          routes: [route_index, route_app_layout], skipped: [],
          source_dir: "pages", generated_at: "2026-05-13"
        )

        expect(output).to include("Layouts — translated to app/views/layouts/<action>.rb")
        expect(output).to include("#   - _app.tsx → app/views/layouts/application.rb")
      end

      it "does not emit a route line for the layout" do
        output = described_class.emit(
          routes: [route_app_layout], skipped: [],
          source_dir: "pages", generated_at: "2026-05-13"
        )

        expect(output).not_to match(/get .*layouts/)
        expect(output).not_to match(/match .*layouts/)
      end

      it "passes ruby -c when only a layout is present" do
        output = described_class.emit(
          routes: [route_app_layout], skipped: [],
          source_dir: "pages", generated_at: "2026-05-13"
        )

        expect { compile_ruby(output) }.not_to raise_error
      end
    end
  end

  def compile_ruby(source)
    RubyVM::InstructionSequence.compile(source)
  end

  describe "Route#url_params" do
    def route_with(path)
      JsxRosetta::PagesRouting::Route.new(
        rails_path: path, controller: "c", action: "a", source_path: "p"
      )
    end

    it "returns an empty list when the path has no params" do
      expect(route_with("/accounts").url_params).to eq([])
    end

    it "extracts a single :id param" do
      expect(route_with("/accounts/:id").url_params).to eq(["id"])
    end

    it "extracts multiple snake_cased params in order" do
      expect(route_with("/policies/:provider_slug/:policy_id/edit").url_params)
        .to eq(%w[provider_slug policy_id])
    end

    it "includes catch-all params" do
      expect(route_with("/docs/*rest").url_params).to eq(["rest"])
    end

    it "includes optional catch-all params" do
      expect(route_with("/accounts/:id(/*extra)").url_params).to eq(%w[id extra])
    end
  end

  describe ".emit_controllers" do
    def make_route(rails_path:, controller:, action:, source_path: "src.tsx")
      JsxRosetta::PagesRouting::Route.new(
        rails_path: rails_path, controller: controller, action: action, source_path: source_path
      )
    end

    it "produces one ControllerFile per controller in the route table" do
      routes = [
        make_route(rails_path: "/", controller: "pages", action: "index"),
        make_route(rails_path: "/accounts", controller: "accounts", action: "index"),
        make_route(rails_path: "/accounts/:id", controller: "accounts", action: "show")
      ]

      files = described_class.emit_controllers(routes: routes)

      expect(files.map(&:path)).to contain_exactly("accounts_controller.rb", "pages_controller.rb")
    end

    it "renders an ApplicationController-inheriting class with one def per action" do
      routes = [
        make_route(rails_path: "/accounts", controller: "accounts", action: "index"),
        make_route(rails_path: "/accounts/:id", controller: "accounts", action: "show")
      ]

      contents = described_class.emit_controllers(routes: routes).first.contents

      expect(contents).to include("class AccountsController < ApplicationController")
      expect(contents).to include("  def index\n  end")
      expect(contents).to include("  def show\n  end")
      expect { compile_ruby(contents) }.not_to raise_error
    end

    it "lists URL params in a comment above each action" do
      routes = [
        make_route(rails_path: "/policies/:provider_slug/:policy_id/edit",
                   controller: "policies", action: "edit")
      ]

      contents = described_class.emit_controllers(routes: routes).first.contents

      expect(contents).to include("  # params: :provider_slug, :policy_id\n  def edit")
    end

    it "alphabetizes actions inside a controller" do
      routes = [
        make_route(rails_path: "/users/:id/edit", controller: "users", action: "edit"),
        make_route(rails_path: "/users", controller: "users", action: "index"),
        make_route(rails_path: "/users/new", controller: "users", action: "new"),
        make_route(rails_path: "/users/:id", controller: "users", action: "show")
      ]

      contents = described_class.emit_controllers(routes: routes).first.contents

      positions = %w[edit index new show].map { |a| contents.index("def #{a}") }
      expect(positions).to eq(positions.sort)
    end

    it "upper-camelizes multi-word controller names" do
      routes = [
        make_route(rails_path: "/policy_providers", controller: "policy_providers", action: "index")
      ]

      contents = described_class.emit_controllers(routes: routes).first.contents

      expect(contents).to include("class PolicyProvidersController < ApplicationController")
    end

    it "dedupes identical (controller, action) pairs across multiple source files" do
      routes = [
        make_route(rails_path: "/accounts/:id", controller: "accounts", action: "show",
                   source_path: "accounts/[id].tsx"),
        make_route(rails_path: "/accounts/:id", controller: "accounts", action: "show",
                   source_path: "accounts/[id]/index.tsx")
      ]

      contents = described_class.emit_controllers(routes: routes).first.contents

      expect(contents.scan("def show").size).to eq(1)
    end

    context "with namespace (B3 / B5)" do
      def namespaced_route(rails_path:, controller:, action:, namespace:)
        JsxRosetta::PagesRouting::Route.new(
          rails_path: rails_path, controller: controller, action: action,
          source_path: "src.tsx", namespace: namespace
        )
      end

      it "lands the controller file in a namespaced subdirectory" do
        routes = [
          namespaced_route(rails_path: "/admin/users", controller: "users",
                           action: "index", namespace: ["admin"]),
          namespaced_route(rails_path: "/admin/users/:id", controller: "users",
                           action: "show", namespace: ["admin"])
        ]

        files = described_class.emit_controllers(routes: routes)

        expect(files.map(&:path)).to contain_exactly("admin/users_controller.rb")
      end

      it "emits the qualified class declaration with the namespace as a Ruby module" do
        routes = [
          namespaced_route(rails_path: "/admin/users", controller: "users",
                           action: "index", namespace: ["admin"])
        ]

        contents = described_class.emit_controllers(routes: routes).first.contents

        expect(contents).to include("class Admin::UsersController < ApplicationController")
      end

      it "splits two-level namespaces into nested module path and class name" do
        routes = [
          namespaced_route(rails_path: "/admin/billing/invoices", controller: "invoices",
                           action: "index", namespace: %w[admin billing])
        ]

        files = described_class.emit_controllers(routes: routes)
        contents = files.first.contents

        expect(files.first.path).to eq("admin/billing/invoices_controller.rb")
        expect(contents).to include("class Admin::Billing::InvoicesController < ApplicationController")
      end

      it "references the namespaced view path in the wiring comment" do
        routes = [
          namespaced_route(rails_path: "/admin/users", controller: "users",
                           action: "index", namespace: ["admin"])
        ]

        contents = described_class.emit_controllers(routes: routes).first.contents

        expect(contents).to include("app/views/admin/users/<action>.rb")
      end
    end
  end

  describe JsxRosetta::PagesRouting::Naming do
    def make_route(rails_path:, controller:, action:)
      JsxRosetta::PagesRouting::Route.new(
        rails_path: rails_path, controller: controller, action: action, source_path: "src.tsx"
      )
    end

    it "names root the special `root` token" do
      route = make_route(rails_path: "/", controller: "pages", action: "index")
      expect(described_class.route_name(route)).to eq("root")
      expect(described_class.url_helper_name(route)).to eq("root_path")
    end

    it "names index actions with the plural controller" do
      route = make_route(rails_path: "/accounts", controller: "accounts", action: "index")
      expect(described_class.route_name(route)).to eq("accounts")
      expect(described_class.url_helper_name(route)).to eq("accounts_path")
    end

    it "names show actions with the singular controller" do
      route = make_route(rails_path: "/accounts/:id", controller: "accounts", action: "show")
      expect(described_class.route_name(route)).to eq("account")
      expect(described_class.url_helper_name(route)).to eq("account_path")
    end

    it "names new actions as `new_<singular>`" do
      route = make_route(rails_path: "/policies/new", controller: "policies", action: "new")
      expect(described_class.route_name(route)).to eq("new_policy")
    end

    it "names edit actions as `edit_<singular>`" do
      route = make_route(rails_path: "/policies/:id/edit", controller: "policies", action: "edit")
      expect(described_class.route_name(route)).to eq("edit_policy")
    end

    it "names other actions as `<controller>_<action>`" do
      route = make_route(rails_path: "/about", controller: "pages", action: "about")
      expect(described_class.route_name(route)).to eq("pages_about")
    end

    describe "with namespace" do
      def make_namespaced(rails_path:, controller:, action:, namespace:)
        JsxRosetta::PagesRouting::Route.new(
          rails_path: rails_path, controller: controller, action: action,
          source_path: "src.tsx", namespace: namespace
        )
      end

      it "prefixes the namespace on index actions" do
        route = make_namespaced(rails_path: "/admin/users", controller: "users",
                                action: "index", namespace: ["admin"])
        expect(described_class.route_name(route)).to eq("admin_users")
      end

      it "prefixes the namespace on show actions" do
        route = make_namespaced(rails_path: "/admin/users/:id", controller: "users",
                                action: "show", namespace: ["admin"])
        expect(described_class.route_name(route)).to eq("admin_user")
      end

      it "joins multi-level namespaces with underscores" do
        route = make_namespaced(rails_path: "/admin/billing/invoices", controller: "invoices",
                                action: "index", namespace: %w[admin billing])
        expect(described_class.route_name(route)).to eq("admin_billing_invoices")
      end

      it "prefixes namespace on a route-group route (URL-invisible namespace)" do
        route = make_namespaced(rails_path: "/about", controller: "pages",
                                action: "about", namespace: ["marketing"])
        expect(described_class.route_name(route)).to eq("marketing_pages_about")
      end
    end
  end

  describe JsxRosetta::PagesRouting::HrefRewriter do
    def route(rails_path:, controller:, action:)
      JsxRosetta::PagesRouting::Route.new(
        rails_path: rails_path, controller: controller, action: action, source_path: "src.tsx"
      )
    end

    let(:routes) do
      [
        route(rails_path: "/", controller: "pages", action: "index"),
        route(rails_path: "/accounts", controller: "accounts", action: "index"),
        route(rails_path: "/accounts/:id", controller: "accounts", action: "show"),
        route(rails_path: "/accounts/:id/edit", controller: "accounts", action: "edit"),
        route(rails_path: "/policies/:provider_slug/:policy_id/edit", controller: "policies", action: "edit")
      ]
    end

    subject(:rewriter) { described_class.new(routes) }

    describe "#rewrite_literal" do
      it "rewrites the root path" do
        expect(rewriter.rewrite_literal("/")).to eq("root_path")
      end

      it "rewrites a collection path" do
        expect(rewriter.rewrite_literal("/accounts")).to eq("accounts_path")
      end

      it "rewrites a member path with a numeric literal" do
        expect(rewriter.rewrite_literal("/accounts/123")).to eq("account_path(123)")
      end

      it "rewrites a member path with a non-numeric literal as a string" do
        expect(rewriter.rewrite_literal("/accounts/abc")).to eq("account_path('abc')")
      end

      it "rewrites a nested edit path" do
        expect(rewriter.rewrite_literal("/accounts/42/edit")).to eq("edit_account_path(42)")
      end

      it "returns nil for an unknown path" do
        expect(rewriter.rewrite_literal("/nope/123")).to be_nil
      end

      it "returns nil for an external URL" do
        expect(rewriter.rewrite_literal("//cdn.example/foo")).to be_nil
      end

      it "returns nil for paths with query strings" do
        expect(rewriter.rewrite_literal("/accounts?tab=1")).to be_nil
      end

      it "returns nil for paths with anchors" do
        expect(rewriter.rewrite_literal("/accounts#top")).to be_nil
      end

      context "with namespaced routes (B3)" do
        let(:routes) do
          [
            route(rails_path: "/admin/users", controller: "users", action: "index").with(namespace: ["admin"]),
            route(rails_path: "/admin/users/:id", controller: "users", action: "show").with(namespace: ["admin"])
          ]
        end

        it "rewrites a namespaced collection path with the namespace-prefixed helper" do
          expect(rewriter.rewrite_literal("/admin/users")).to eq("admin_users_path")
        end

        it "rewrites a namespaced member path with the singular namespace-prefixed helper" do
          expect(rewriter.rewrite_literal("/admin/users/42")).to eq("admin_user_path(42)")
        end
      end
    end

    describe "#rewrite_template" do
      it "rewrites a single-hole template" do
        segments = [[:literal, "/accounts/"], [:hole, "id"], [:literal, ""]]
        expect(rewriter.rewrite_template(segments)).to eq("account_path(id)")
      end

      it "rewrites a multi-hole template" do
        segments = [
          [:literal, "/policies/"], [:hole, "slug"],
          [:literal, "/"], [:hole, "policy_id"], [:literal, "/edit"]
        ]
        expect(rewriter.rewrite_template(segments)).to eq("edit_policy_path(slug, policy_id)")
      end

      it "returns nil when a hole is mixed with literal text in the same segment" do
        segments = [[:literal, "/accounts/x"], [:hole, "id"], [:literal, ""]]
        expect(rewriter.rewrite_template(segments)).to be_nil
      end

      it "returns nil for a path that does not match any route" do
        segments = [[:literal, "/widgets/"], [:hole, "id"], [:literal, ""]]
        expect(rewriter.rewrite_template(segments)).to be_nil
      end
    end

    describe ".parse_template_source" do
      it "parses a no-hole template" do
        expect(described_class.parse_template_source("`/foo`")).to eq([[:literal, "/foo"]])
      end

      it "parses a single-hole template" do
        expect(described_class.parse_template_source("`/foo/${bar}`"))
          .to eq([[:literal, "/foo/"], [:hole, "bar"], [:literal, ""]])
      end

      it "parses a multi-hole template" do
        expect(described_class.parse_template_source("`/a/${b}/c/${d}/e`"))
          .to eq([[:literal, "/a/"], [:hole, "b"], [:literal, "/c/"], [:hole, "d"], [:literal, "/e"]])
      end

      it "returns nil for non-template input" do
        expect(described_class.parse_template_source("'/foo'")).to be_nil
        expect(described_class.parse_template_source("foo()")).to be_nil
      end

      it "returns nil when an interpolation contains nested braces" do
        # `${foo({})}` — inner `{}` breaks the [^{}]+ guard.
        expect(described_class.parse_template_source("`/a/${foo({})}`")).to be_nil
      end
    end
  end
end
