# frozen_string_literal: true

RSpec.describe JsxRosetta::Backend::Phlex do
  def files_for(jsx_source, **backend_options)
    backend = described_class.new(**backend_options)
    JsxRosetta.lower(jsx_source) # parses + lowers; we want the IR::Component
    component = JsxRosetta.lower(jsx_source)
    backend.emit(component).to_h { |file| [file.path, file.contents] }
  end

  def file_contents(jsx_source, path, **backend_options)
    files_for(jsx_source, **backend_options).fetch(path)
  end

  describe "naming strategies" do
    let(:source) { "function FlashyHeader() { return <h1>hi</h1>; }" }

    it "default mode emits a bare class with snake_case filename" do
      files = files_for(source)

      expect(files.keys).to eq(["flashy_header.rb"])
      expect(files["flashy_header.rb"]).to include("class FlashyHeader < Phlex::HTML")
      expect(files["flashy_header.rb"]).not_to include("module ")
    end

    it "suffix: \"Component\" adds the suffix to class and filename" do
      files = files_for(source, suffix: "Component")

      expect(files.keys).to eq(["flashy_header_component.rb"])
      expect(files["flashy_header_component.rb"]).to include("class FlashyHeaderComponent < Phlex::HTML")
    end

    it "suffix: \"View\" uses the custom suffix" do
      files = files_for(source, suffix: "View")

      expect(files.keys).to eq(["flashy_header_view.rb"])
      expect(files["flashy_header_view.rb"]).to include("class FlashyHeaderView < Phlex::HTML")
    end

    it "namespace: wraps the class in a module" do
      files = files_for(source, namespace: "Components")

      expect(files.keys).to eq(["flashy_header.rb"])
      content = files["flashy_header.rb"]
      expect(content).to include("module Components")
      expect(content).to include("  class FlashyHeader < Phlex::HTML")
      expect(content).to include("end\nend\n")
    end

    it "namespace: supports nested namespaces" do
      content = file_contents(source, "flashy_header.rb", namespace: "Web::Views")

      expect(content).to include("module Web::Views")
    end

    it "raises when both suffix and namespace are passed" do
      expect { described_class.new(suffix: "Component", namespace: "Components") }
        .to raise_error(ArgumentError, /not both/)
    end
  end

  describe "core IR rendering" do
    it "renders a single HTML element with no props as a bare tag call" do
      content = file_contents("function X() { return <hr />; }", "x.rb")

      expect(content).to include("def view_template\n    hr\n  end")
    end

    it "renders a leaf element with literal attributes as kwargs" do
      content = file_contents('function X() { return <a href="/about" />; }', "x.rb")

      expect(content).to include('a(href: "/about")')
    end

    it "renders interpolated attribute values via the translator" do
      content = file_contents("function X({ url }) { return <a href={url} />; }", "x.rb")

      expect(content).to include("a(href: @url)")
    end

    it "renders an Element with children inside a do/end block" do
      content = file_contents("function X() { return <p>Hello</p>; }", "x.rb")

      expect(content).to include("p do\n      plain \"Hello\"\n    end")
    end

    it "emits hyphenated attributes as snake_case kwargs (Phlex auto-converts to hyphens at render time)" do
      content = file_contents('function X() { return <div data-testid="x" aria-label="y"/>; }', "x.rb")

      expect(content).to include('data_testid: "x"')
      expect(content).to include('aria_label: "y"')
      expect(content).not_to include("**{")
    end

    it "preserves camelCase attribute names verbatim (SVG attrs like viewBox stay unchanged)" do
      content = file_contents('function X() { return <svg viewBox="0 0 10 10" />; }', "x.rb")

      expect(content).to include('viewBox: "0 0 10 10"')
      # Phlex only hyphenates underscores; camelCase stays camelCase, which
      # is what SVG attributes need.
      expect(content).not_to include("view_box")
    end

    it "treats className with a string literal as a class: kwarg" do
      content = file_contents('function X() { return <div className="btn primary"/>; }', "x.rb")

      expect(content).to include('class: "btn primary"')
    end

    it "drops React `key` (DOM-irrelevant)" do
      content = file_contents("function X({ id }) { return <li key={id}>x</li>; }", "x.rb")

      expect(content).not_to include("key:")
      expect(content).to include("li do")
    end

    it "renders a Fragment as sequential top-level expressions (no wrapper)" do
      content = file_contents("function X() { return <><h1>A</h1><p>B</p></>; }", "x.rb")

      expect(content).to include("h1 do")
      expect(content).to include("p do")
      expect(content).not_to include("fragment")
    end
  end

  describe "control flow" do
    it "renders {cond ? <A/> : <B/>} as if/else inside the template" do
      content = file_contents(
        "function X({ open }) { return <div>{open ? <a /> : <b />}</div>; }",
        "x.rb"
      )

      expect(content).to include("if @open")
      expect(content).to include("a\n      else")
      expect(content).to include("b\n      end")
    end

    it "renders {items.map((item) => <li/>)} as items.each do |item|" do
      content = file_contents(
        "function X({ items }) { return <ul>{items.map((item) => <li />)}</ul>; }",
        "x.rb"
      )

      expect(content).to include("@items.each do |item|")
      expect(content).to include("    li\n      end")
    end

    it "renders top-level `return cond ? <A/> : <B/>` as if/else at template top" do
      content = file_contents(
        "function X({ open }) { return open ? <a /> : <b />; }",
        "x.rb"
      )

      expect(content).to include("def view_template\n    if @open")
    end
  end

  describe "ComponentInvocation" do
    it "renders <Card title=\"x\"/> as `render Card.new(title: \"x\")` (default mode)" do
      content = file_contents('function X() { return <Card title="x"/>; }', "x.rb")

      expect(content).to include('render Card.new(title: "x")')
    end

    it "appends the suffix to the invoked component class in suffix mode" do
      content = file_contents('function X() { return <Card title="x"/>; }', "x_component.rb", suffix: "Component")

      expect(content).to include("render CardComponent.new")
    end

    it "leaves bare names under namespace mode (constant lookup finds the peer)" do
      content = file_contents('function X() { return <Card title="x"/>; }', "x.rb", namespace: "Components")

      expect(content).to include("render Card.new")
      expect(content).not_to include("Components::Card")
    end

    it "lowers <Foo.Bar/> to Foo::Bar" do
      content = file_contents("function X() { return <Foo.Bar/>; }", "x.rb")

      expect(content).to include("render Foo::Bar.new")
    end

    it "passes children through a block (default-slot pattern)" do
      content = file_contents("function X() { return <Card><p>hi</p></Card>; }", "x.rb")

      expect(content).to include("render Card.new do")
      expect(content).to include("p do")
    end
  end

  describe "default slot (children prop)" do
    it "renders <%= content %> as `yield` for `children`" do
      source = "function Card({ children, title }) { return <div>{title}{children}</div>; }"
      content = file_contents(source, "card.rb")

      expect(content).to include("yield")
    end

    it "excludes `children` from the initializer kwargs" do
      source = "function Card({ children, title }) { return <div>{title}{children}</div>; }"
      content = file_contents(source, "card.rb")

      expect(content).to include("def initialize(title: nil)")
      expect(content).not_to include("children: nil")
    end
  end

  describe "Stimulus emission" do
    let(:source) { "function X() { return <button onClick={() => doThing()}>Click</button>; }" }

    it "emits a sibling _controller.js file alongside the .rb" do
      files = files_for(source)

      expect(files.keys).to contain_exactly("x.rb", "x_controller.js")
    end

    it "stamps data-controller / data-action on the root element as snake_case kwargs" do
      content = file_contents(source, "x.rb")

      expect(content).to include('data_controller: "x"')
      expect(content).to include('data_action: "click->x#clickHandler"')
    end

    it "skeleton controller exports an extends Controller class with the inferred method" do
      content = file_contents(source, "x_controller.js")

      expect(content).to include('import { Controller } from "@hotwired/stimulus"')
      expect(content).to include("export default class extends Controller {")
      expect(content).to include("clickHandler(event) {")
    end

    it "preserves the original handler body as a TODO comment" do
      content = file_contents(source, "x_controller.js")

      expect(content).to include("// TODO: translate from the original JSX handler:")
      expect(content).to include("doThing()")
    end
  end

  describe "TODO markers" do
    it "surfaces unresolved-identifier TODO in interpolation positions" do
      source = "function X() { return <p>{someGlobal}</p>; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("# TODO: unresolved identifier \"someGlobal\"")
      expect(content).to include("plain some_global")
    end

    it "does NOT inline a TODO comment in attribute-value positions (would break the hash-splat syntax)" do
      # Trade-off: unresolved-identifier markers in attributes can't be emitted
      # inline because they'd land inside `**{ ... }` where `# ... }` swallows
      # the closing brace. The bare snake_case reference surfaces at runtime
      # (NameError on the missing ivar) instead.
      source = "function X() { return <p data-x={someGlobal} />; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("some_global")
      expect(content).not_to include("# TODO: unresolved identifier")
    end
  end

  describe "initializer + props" do
    it "snake_cases each prop into a kwarg + matching ivar" do
      source = "function X({ firstName, lastName }) { return <p>hi</p>; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("def initialize(first_name: nil, last_name: nil)")
      expect(content).to include("@first_name = first_name")
      expect(content).to include("@last_name = last_name")
    end

    it "captures rest-binding as **kwargs" do
      source = "function X({ a, ...rest }) { return <p>hi</p>; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("def initialize(a: nil, **rest)")
      expect(content).to include("@rest = rest")
    end

    it "renders prop default expressions in the kwarg signature" do
      source = 'function X({ label = "Click" }) { return <button>{label}</button>; }'
      content = file_contents(source, "x.rb")

      expect(content).to include('def initialize(label: "Click")')
    end

    it "skips the initializer entirely when the component takes no props" do
      content = file_contents("function X() { return <p>hi</p>; }", "x.rb")

      expect(content).not_to include("def initialize")
    end
  end

  describe "react hooks + local bindings TODO blocks" do
    it "emits a hooks TODO block as inline comments at the top of view_template" do
      source = <<~JS
        function X() {
          const [count, setCount] = useState(0);
          return <p>{count}</p>;
        }
      JS
      content = file_contents(source, "x.rb")

      expect(content).to include("# TODO: React hooks detected")
      expect(content).to include("const [count, setCount] = useState(0)")
    end

    it "emits a local-bindings TODO block for non-JSX const declarations" do
      source = <<~JS
        function X() {
          const greeting = computeGreeting();
          return <p>{greeting}</p>;
        }
      JS
      content = file_contents(source, "x.rb")

      expect(content).to include("# TODO: translate JS to Ruby")
      expect(content).to include("const greeting = computeGreeting()")
    end
  end
end
