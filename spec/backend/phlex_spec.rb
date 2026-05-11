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

    it "snake_cases camelCase JSX prop names for component invocations" do
      # Component invocations are Ruby method calls; their kwargs should
      # follow snake_case. HTML element attrs preserve camelCase (SVG
      # `viewBox`) — different context, different rule.
      content = file_contents('function X() { return <Select defaultValue="x" pageSize={10} />; }', "x.rb")

      expect(content).to include("default_value:")
      expect(content).to include("page_size:")
      expect(content).not_to include("defaultValue:")
      expect(content).not_to include("pageSize:")
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

    it "emits a collision marker when a handler name was uniquified" do
      # Two `onClick={handleReset}` handlers in one component would
      # silently rename the second to `handleReset2`. Without a
      # marker, the human reviewer wouldn't know the rename happened.
      collision_source = <<~JSX
        function X({ handleReset }) {
          return (
            <div>
              <button onClick={handleReset}>a</button>
              <button onClick={handleReset}>b</button>
            </div>
          );
        }
      JSX
      content = file_contents(collision_source, "x_controller.js")

      expect(content).to include("handleReset(event) {")
      expect(content).to include("handleReset2(event) {")
      expect(content).to include('// NOTE: method renamed from "handleReset"')
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

    it "emits valid Ruby (string-literal placeholder) when an interpolation can't be translated" do
      # The translator handles bare identifiers and simple member chains, but
      # bails on expressions like `cloneElement(x, { label })`. Bug would be
      # to emit `plain cloneElement(x, { label })` — invalid Ruby outside a
      # call site (the bare `{ label }` block isn't a hash). We emit a string
      # placeholder + comment instead so `ruby -c` always passes.
      source = "function X({ x, label }) { return <p>{cloneElement(x, { label })}</p>; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("# TODO: translate")
      expect(content).to include("plain \"[untranslated:")
    end
  end

  describe "preserving untranslatable test/iterable expressions" do
    it "wraps an untranslatable conditional test in a TODO and emits `if false`" do
      # Function calls aren't translated by the expression translator —
      # leaving them verbatim could produce JS-isms in the output. We emit
      # a TODO comment above the `if` and use `false` as a safe placeholder.
      source = "function X({ items }) { return items.includes(x) ? <p /> : <q />; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("# TODO: translate condition: items.includes(x)")
      expect(content).to include("if false")
    end

    it "translates a comparison test (value !== null) to Ruby (@value != nil)" do
      # Binary/logical operator translation handles `!==`, `===`, `<`, `>`,
      # `&&`, `||`, `??`, etc. — these used to bail to `if false` placeholders.
      source = "function X({ value }) { return value !== null ? <p>have</p> : <NilValue />; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("if @value != nil")
      expect(content).not_to include("# TODO: translate condition")
    end

    it "wraps an untranslatable loop iterable in a TODO and emits []" do
      source = "function X({ items }) { return <ul>{items.filter(x => x.active).map((i) => <li />)}</ul>; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("# TODO: translate iterable:")
      expect(content).to include("[].each do")
    end

    it "still emits the translated condition when it parses cleanly" do
      content = file_contents("function X({ open }) { return open ? <a /> : <b />; }", "x.rb")

      expect(content).to include("if @open")
      expect(content).not_to include("# TODO: translate condition")
    end
  end

  describe "binary and logical operator translation" do
    it "translates a relational comparison on a member chain" do
      source = "function X({ email }) { return email.emailAttachments.length > 0 ? <p /> : <q />; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("if @email.email_attachments.length > 0")
    end

    it "translates `===` and `!==` to `==` and `!=`" do
      source = "function X({ status }) { return status === \"open\" ? <a /> : <b />; }"
      content = file_contents(source, "x.rb")

      expect(content).to include('if @status == "open"')
    end

    it "translates `??` to `||`" do
      content = file_contents(
        "function X({ value }) { return (value ?? defaultValue) ? <a /> : <b />; }", "x.rb"
      )

      expect(content).to include("if @value || default_value")
    end

    it "translates `&&` and `||` between sub-expressions" do
      source = "function X({ a, b }) { return a > 0 && b < 5 ? <p /> : <q />; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("if @a > 0 && @b < 5")
    end

    it "translates optional chaining (?.) to Ruby safe-nav (&.)" do
      source = "function X({ user }) { return <p>{user?.profile?.name}</p>; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("plain @user&.profile&.name")
    end

    it "translates optional chaining inside a binary comparison" do
      source = "function X({ user }) { return user?.posts?.length > 0 ? <p /> : <q />; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("if @user&.posts&.length > 0")
    end

    it "does not partially translate a ternary expression in attribute position" do
      # Regression: STRING_LITERAL used to be greedy (`/\A(['"])(.*)\1\z/m`),
      # so an expression like `partyType === "ORG" ? "X" : "Y"` would match
      # because `"ORG" ? "X" : "Y"` was accepted as a single string. The
      # binary-operator translator would then emit valid-looking Ruby with
      # the JS ternary spliced in verbatim — but Ruby's parser doesn't allow
      # the `? :` continuation across a newline so the output failed to
      # parse. The attribute now bails to `nil` + a TODO instead.
      source = <<~JSX
        function X({ values }) {
          return <Field value={values.partyType === "ORGANIZATION" ? "Organization" : "Person"} />;
        }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).to include("value: nil")
      expect(content).to include("# TODO: attribute \"value\" dropped")
      # Verify the kwarg position has `nil`, not a partial ternary fragment.
      expect(content).not_to match(/value:\s*"Organization"/)
      expect(content).not_to match(/value:\s*@values\.party_type/)
    end
  end

  describe "preserving untranslatable attribute values" do
    it "emits a TODO comment line above the element when a JSX-element prop can't translate" do
      source = "function X() { return <Button icon={<LeftOutlined size={12} />} />; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("# TODO: attribute \"icon\" dropped — couldn't translate:")
      expect(content).to include("<LeftOutlined")
      expect(content).to include("icon: nil")
    end

    it "recursively translates an array-of-objects literal prop into a Ruby array of hashes" do
      # Pre-Gap-H, this emitted a TODO + `options: nil`. With recursive
      # object/array lowering, the actual data shape carries through.
      source = <<~JS
        function X() {
          return <Select options={[{ value: 10, label: "a" }, { value: 25, label: "b" }]} />;
        }
      JS
      content = file_contents(source, "x.rb")

      expect(content).to include('options: [{ value: 10, label: "a" }, { value: 25, label: "b" }]')
      expect(content).not_to include("# TODO: attribute \"options\" dropped")
    end

    it "does NOT emit a TODO when an attribute interpolation translates cleanly" do
      content = file_contents("function X({ open }) { return <p hidden={open} />; }", "x.rb")

      expect(content).not_to include("# TODO:")
      expect(content).to include("hidden: @open")
    end
  end

  describe "Gap A: known-local-but-unmodeled bindings" do
    it "emits `nil` instead of a bare snake_case reference for a hook-tuple name" do
      # `const [count, setCount] = useState(0); ... {count}` — without
      # capture, `plain count` NameErrors at render time. With capture,
      # we emit `plain nil` so the file at least loads, and the hook
      # TODO block hints at what to fill in.
      source = <<~JSX
        function X() {
          const [count, setCount] = useState(0);
          return <p>{count}</p>;
        }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).to include("plain nil")
      expect(content).not_to match(/plain count(?!\w)/)
    end

    it "emits `nil` for an object-destructured local in an attribute position" do
      source = <<~JSX
        function X() {
          const { className } = props;
          return <p data-x={className} />;
        }
      JSX
      content = file_contents(source, "x.rb")

      # Attribute splice — `data_x: nil` is valid Ruby, file loads.
      expect(content).to include("data_x: nil")
    end

    it "does NOT emit `nil.member` when a local binding appears as a member-chain root" do
      # `token.blue` previously translated to `nil.blue` (NoMethodError at
      # render time) because the local-binding nil-substitution kicked in
      # for the root. Member chains now fall through to the snake_case
      # bare reference, which surfaces as a NameError — still wrong but
      # at least debuggable.
      source = <<~JSX
        function X() {
          const { token } = useToken();
          return <div style={{ color: token.blue }} />;
        }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).not_to include("nil.blue")
      expect(content).to include("token.blue")
    end
  end

  describe "Gap J: member-expression destructuring" do
    it "resolves `const { Content } = Layout; <Content/>` to `Layout::Content.new`" do
      source = <<~JSX
        function X() {
          const { Content } = Layout;
          return <Content>x</Content>;
        }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).to include("render Layout::Content.new")
    end
  end

  describe "Gap residuals: comment + template-literal escaping" do
    it "comments every line of a multi-line JSX comment" do
      # A bare `# ` on the first line only would leave subsequent lines
      # as raw Ruby code — broke `ruby -c` parsing in two stress-test files.
      source = <<~JSX
        function X() {
          return (
            <div>
              {/* TODO:
                  <Foo bar={baz} />
                  next line */}
            </div>
          );
        }
      JSX
      content = file_contents(source, "x.rb")

      content.lines.each do |line|
        # Inside the view_template body, any line that isn't the open/close
        # of the function or the wrapping div should either be empty or
        # start with `#` (a comment) — no raw `<Foo` etc.
        next if line.strip.empty? || line.strip.start_with?("class", "end", "def", "div")

        expect(line.strip).to start_with("#") if line.include?("<Foo")
      end
    end

    it "escapes `\"` inside the literal portions of a translated template literal" do
      # `\`with "quoted" \${name} text\`` would translate to
      # `"with "quoted" #{@name} text"` — the inner `"` terminates the
      # Ruby string and breaks `ruby -c`. We escape `"` and `\`.
      source = 'function X({ name }) { return <p>{`hi "${name}" there`}</p>; }'
      content = file_contents(source, "x.rb")

      expect(content).to include(%q(plain "hi \"#{@name}\" there"))
    end
  end

  describe "Gap H array-literal as `.map(...)` iterable" do
    it "translates `[\"a\", \"b\"].map((x) => <li/>)` into a literal-array iteration" do
      # Before this fix, the iterable lowered to a verbatim Interpolation
      # whose source couldn't translate (the translator only handles
      # bare identifiers / member chains), bailed to `[]`, and emitted
      # `[].each do |x|` — dropping the actual elements.
      source = <<~JSX
        function X() {
          return <ul>{["a", "b"].map((x) => <li>{x}</li>)}</ul>;
        }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).to include('["a", "b"].each do |x|')
      expect(content).not_to include("[].each do")
    end
  end

  describe "Gap H: recursive object/array/lambda translation" do
    it "translates a simple numeric array prop into a Ruby array" do
      content = file_contents("function X() { return <Select tabs={[1, 2, 3]} />; }", "x.rb")

      expect(content).to include("tabs: [1, 2, 3]")
    end

    it "translates an array-of-hashes prop and snake_cases identifier keys" do
      source = <<~JS
        function X() {
          return <Select options={[{ value: 10, dataLabel: "10 / page" }]} />;
        }
      JS
      content = file_contents(source, "x.rb")

      expect(content).to include('options: [{ value: 10, data_label: "10 / page" }]')
    end

    it "translates a nested object literal" do
      source = <<~JS
        function X() {
          return <Form initialValues={{ outer: { inner: 1 } }} />;
        }
      JS
      content = file_contents(source, "x.rb")

      expect(content).to include("initial_values: { outer: { inner: 1 } }")
    end

    it "extracts a function-valued property to a method on the class" do
      source = <<~JS
        function X({ value }) {
          return <Table columns={[{ title: "Y", render: (v) => <span>{v}</span> }]} />;
        }
      JS
      content = file_contents(source, "x.rb")

      # Lambda extracted to a private method, referenced by method(:name).
      expect(content).to include("method(:render_render)")
      expect(content).to include("def render_render(v)")
      expect(content).to include("span do")
      expect(content).to include("private")
    end

    it "uses deterministic method names per attribute name when multiple lambdas appear" do
      source = <<~JS
        function X() {
          return <Table columns={[
            { title: "A", render: (v) => <p>{v}</p> },
            { title: "B", render: (v) => <span>{v}</span> }
          ]} />;
        }
      JS
      content = file_contents(source, "x.rb")

      expect(content).to include("render_render")
      expect(content).to include("render_render2")
    end

    it "preserves verbatim Interpolation behavior for unsupported shapes (spread inside object)" do
      # Spread inside object literal isn't recognized — falls back to verbatim.
      source = <<~JS
        function X({ extra }) {
          return <Card props={{ ...extra, a: 1 }} />;
        }
      JS
      content = file_contents(source, "x.rb")

      # Falls back to TODO + nil (translator can't parse `...extra` in the
      # expression-string path either).
      expect(content).to include("# TODO: attribute \"props\" dropped")
    end
  end

  describe "Gap G: plain/raw hint for ReactNode-typed props" do
    it "emits a `raw` comment hint when an interpolation resolves to a bare @ivar prop" do
      # `plain @children` HTML-escapes the value, which corrupts ReactNode-
      # typed props (children, icons, prebuilt markup). We can't tell at
      # translation time, so default to safe `plain` and surface a hint.
      content = file_contents("function X({ extra }) { return <p>{extra}</p>; }", "x.rb")

      expect(content).to include("plain @extra # NOTE: use `raw` instead of `plain`")
    end

    it "does NOT emit a hint when the interpolation resolves to a member chain" do
      # `plain @post.title` is unambiguously a string-ish leaf; no hint needed.
      content = file_contents("function X({ post }) { return <p>{post.title}</p>; }", "x.rb")

      expect(content).to include("plain @post.title")
      expect(content).not_to include("ReactNode-typed")
    end

    it "does NOT emit a hint on plain string-literal text" do
      content = file_contents("function X() { return <p>hello</p>; }", "x.rb")

      expect(content).not_to include("ReactNode-typed")
    end
  end

  describe "Gap E: module-level constants" do
    it "emits a TODO comment block above the class for top-level const declarations" do
      source = <<~JSX
        const FOO = 400;
        function X() { return <p>{FOO}</p>; }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).to include("# TODO: module-level constants")
      expect(content).to include("const FOO = 400;")
      # And the prefix lands above the class definition.
      expect(content.index("# TODO: module-level constants")).to be < content.index("class X")
    end

    it "doesn't emit a prefix when there are no module-level constants" do
      content = file_contents("function X() { return <p />; }", "x.rb")

      expect(content).not_to include("module-level constants")
    end
  end

  describe "Gap D: render-prop / function-as-children" do
    it "emits a Ruby block with snake_cased params on the parent render call" do
      source = <<~JSX
        function X() {
          return <Form.List>{(fields) => <p>{fields}</p>}</Form.List>;
        }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).to include("render Form::List.new do |fields|")
      expect(content).to include("plain fields")
      expect(content).to include("end")
    end

    it "snake_cases camelCase params" do
      source = <<~JSX
        function X() {
          return <Form.List>{(fieldList) => <p />}</Form.List>;
        }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).to include("do |field_list|")
    end
  end

  describe "Gap F: spread-of-nil wrapper" do
    it "wraps a spread expression in `(… || {})` so a nil prop default doesn't crash render" do
      # `<div {...maybeNil}>` lowers to a spread of `maybeNil`. If
      # `maybeNil` is `nil` at render time, `**nil` raises. Wrapping
      # in `(… || {})` is cheap and idempotent.
      source = "function X({ gridOptions }) { return <div {...gridOptions} />; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("**(@grid_options || {})")
      expect(content).not_to match(/\*\*@grid_options(?!\s*\|)/)
    end

    it "wraps spread on a component invocation as well" do
      source = "function X({ rest }) { return <Card {...rest} />; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("**(@rest || {})")
    end
  end

  describe "Identifier-bound hook locals at use sites" do
    # `const handleChange = useCallback(...)` is a hook with an Identifier
    # binding (not a destructure). Without recording the name, the use
    # site emits `on_change: handle_change` referencing a method that
    # doesn't exist on the class — NameError at render time. Recording
    # the name routes it through the known-local path, which emits `nil`.
    it "translates a useCallback identifier use site as nil instead of a bare snake_case ref" do
      source = <<~JSX
        function X() {
          const handleChange = useCallback(() => 1, []);
          return <Select onChange={handleChange} />;
        }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).to include("on_change: nil")
      expect(content).not_to include("on_change: handle_change")
    end
  end

  describe "nested render-function locals" do
    # `const renderHeader = () => <div/>; ... {renderHeader()}` used to
    # emit `plain "[untranslated: renderHeader()]"`. The arrow is now
    # extracted as a private method on the class, and the call site emits
    # the method invocation directly.
    it "extracts a no-arg local arrow as a private method and calls it at the use site" do
      source = <<~JSX
        function X() {
          const renderHeader = () => <h1>Header</h1>;
          return <main>{renderHeader()}</main>;
        }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).to include("  private\n")
      expect(content).to include("def render_header")
      expect(content).to include("h1 do")
      expect(content).to include("plain \"Header\"")
      # use site:
      expect(content).to match(/^\s+render_header$/)
      expect(content).not_to include("[untranslated:")
    end

    it "passes args through and snake_cases param names" do
      source = <<~JSX
        function X({ count }) {
          const renderHeader = (headerCount) => <h1>{headerCount}</h1>;
          return <main>{renderHeader(count)}</main>;
        }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).to include("def render_header(header_count)")
      expect(content).to include("plain header_count")
      expect(content).to match(/render_header\(@count\)/)
    end

    it "leaves an unmatched call (no local arrow binding) as a verbatim TODO" do
      source = "function X() { return <p>{externalFn()}</p>; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("[untranslated: externalFn()]")
    end
  end

  describe "guard whose test resolves to a known local binding" do
    # `error && <X />` where `error` is destructured from a hook collapses
    # to `if nil` in v0.4.0 (the translator returns `"nil"` to make the
    # file load). `if nil` is valid Ruby but the branch silently never
    # renders. Treat `"nil"` as untranslatable so the TODO surfaces.
    it "falls through to the TODO path instead of emitting `if nil`" do
      source = <<~JSX
        function X() {
          const { error } = useQuery();
          return <div>{error && <Banner />}</div>;
        }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).not_to match(/^\s*if nil\s*$/)
      expect(content).to include("# TODO: translate condition: error")
      expect(content).to include("if false")
    end
  end

  describe "Ruby class-name capitalization (JSX lowercase helpers)" do
    it "capitalizes the first letter of a lowercase-named JSX helper" do
      source = "function getNodeIcon({ type }) { return <span>{type}</span>; }"
      files = files_for(source, suffix: "Component")

      expect(files.keys).to eq(["get_node_icon_component.rb"])
      expect(files["get_node_icon_component.rb"]).to include("class GetNodeIconComponent < Phlex::HTML")
      expect(files["get_node_icon_component.rb"]).not_to match(/class get/)
    end

    it "capitalizes correctly under namespace mode too" do
      source = "function textRender({ value }) { return <p>{value}</p>; }"
      content = file_contents(source, "text_render.rb", namespace: "Components")

      expect(content).to include("class TextRender < Phlex::HTML")
    end

    it "leaves PascalCase names unchanged" do
      content = file_contents("function FlashyHeader() { return <h1>x</h1>; }", "flashy_header.rb")

      expect(content).to include("class FlashyHeader < Phlex::HTML")
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
