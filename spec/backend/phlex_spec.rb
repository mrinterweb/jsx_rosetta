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

      expect(content).to include("a(href: '/about')")
    end

    it "renders interpolated attribute values via the translator" do
      content = file_contents("function X({ url }) { return <a href={url} />; }", "x.rb")

      expect(content).to include("a(href: @url)")
    end

    it "renders an Element with children inside a do/end block" do
      content = file_contents("function X() { return <p>Hello</p>; }", "x.rb")

      expect(content).to include("p do\n      plain 'Hello'\n    end")
    end

    it "emits hyphenated attributes as snake_case kwargs (Phlex auto-converts to hyphens at render time)" do
      content = file_contents('function X() { return <div data-testid="x" aria-label="y"/>; }', "x.rb")

      expect(content).to include("data_testid: 'x'")
      expect(content).to include("aria_label: 'y'")
      expect(content).not_to include("**{")
    end

    it "preserves camelCase attribute names verbatim (SVG attrs like viewBox stay unchanged)" do
      content = file_contents('function X() { return <svg viewBox="0 0 10 10" />; }', "x.rb")

      expect(content).to include("viewBox: '0 0 10 10'")
      # Phlex only hyphenates underscores; camelCase stays camelCase, which
      # is what SVG attributes need.
      expect(content).not_to include("view_box")
    end

    it "treats className with a string literal as a class: kwarg" do
      content = file_contents('function X() { return <div className="btn primary"/>; }', "x.rb")

      expect(content).to include("class: 'btn primary'")
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
    it "renders <Card title=\"x\"/> as `render Card.new(title: 'x')` (default mode)" do
      content = file_contents('function X() { return <Card title="x"/>; }', "x.rb")

      expect(content).to include("render Card.new(title: 'x')")
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

      expect(content).to include("data_controller: 'x'")
      expect(content).to include("data_action: 'click->x#clickHandler'")
    end

    it "skeleton controller exports an extends Controller class with the inferred method" do
      content = file_contents(source, "x_controller.js")

      expect(content).to include('import { Controller } from "@hotwired/stimulus"')
      expect(content).to include("export default class extends Controller {")
      expect(content).to include("clickHandler(event) {")
    end

    it "pastes the JSX handler body into the generated Stimulus method" do
      content = file_contents(source, "x_controller.js")

      # The DOM-driven body `doThing()` is valid JS, so we drop it straight
      # into the method instead of leaving the human reviewer with a TODO
      # comment to translate.
      expect(content).to include("clickHandler(event) {")
      expect(content).to include("doThing()")
      expect(content).not_to include("// TODO: translate from the original JSX handler:")
    end

    it "falls back to a TODO comment when the body uses a React state setter" do
      # `setOpen(!open)` references a hook return; we can't run the setter
      # in the browser, so preserve the body as a comment and leave the
      # method body empty for the reviewer to port.
      state_source = "function X() { return <button onClick={() => setOpen(!open)}>x</button>; }"
      content = file_contents(state_source, "x_controller.js")

      expect(content).to include("// TODO: translate from the original JSX handler:")
      expect(content).to include("setOpen(!open)")
      expect(content).to match(%r{clickHandler\(event\) \{\s+// \.\.\.\s+\}})
    end

    it "uses the arrow's parameter name so the pasted body's references resolve" do
      # `(e) => e.currentTarget...` pastes verbatim AND the method's
      # parameter is named `e` to match — body references resolve at runtime.
      param_source = <<~JSX
        function X() {
          return (
            <button onClick={(e) => { e.currentTarget.dataset.x = "y"; }}>
              click
            </button>
          );
        }
      JSX
      content = file_contents(param_source, "x_controller.js")

      expect(content).to include("clickHandler(e) {")
      expect(content).to include('e.currentTarget.dataset.x = "y"')
    end

    it "leaves identifier-bound handlers (no inline arrow body) as a TODO" do
      # `onClick={handleClick}` with `handleClick` not declared locally has
      # no body to paste; the existing identifier-bound TODO behavior stays.
      ident_source = "function X({ handleClick }) { return <button onClick={handleClick}>x</button>; }"
      content = file_contents(ident_source, "x_controller.js")

      expect(content).to include("// TODO: translate from the original JSX handler:")
      expect(content).to include("// originally bound to: handleClick")
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
      expect(content).to include("plain '[untranslated:")
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

    it "translates a comparison test (value !== null) to idiomatic `!@value.nil?`" do
      # Binary/logical operator translation handles `!==`, `===`, `<`, `>`,
      # `&&`, `||`, `??`, etc. — these used to bail to `if false`. We now
      # also rewrite `x == nil` / `x != nil` to `x.nil?` / `!x.nil?` so the
      # output passes Style/NilComparison without user intervention.
      source = "function X({ value }) { return value !== null ? <p>have</p> : <NilValue />; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("if !@value.nil?")
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

      expect(content).to include("if @status == 'open'")
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

      # Dropped attributes that bailed to nil are now omitted entirely
      # (the TODO comment above the element preserves what was lost).
      expect(content).not_to match(/value:\s*nil/)
      expect(content).to include("# TODO: attribute \"value\" dropped")
      # Verify no partial ternary fragment leaked into a kwarg position.
      expect(content).not_to match(/value:\s*"Organization"/)
      expect(content).not_to match(/value:\s*@values\.party_type/)
    end
  end

  describe "preserving untranslatable attribute values" do
    it "emits a JSX component as an inline component-instance value" do
      # `icon={<LeftOutlined size={12} />}` used to drop entirely as a TODO,
      # so any rendered file lost its icons / fallbacks / tooltip bodies.
      # Now lowers as IR::ComponentInvocation and emits inline so the
      # receiving Ruby component can `render @icon`.
      source = "function X() { return <Button icon={<LeftOutlined size={12} />} />; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("icon: LeftOutlined.new(size: 12)")
      expect(content).not_to include('# TODO: attribute "icon" dropped')
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

      expect(content).to include("options: [{ value: 10, label: 'a' }, { value: 25, label: 'b' }]")
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

    it "fails translation when a local binding appears as a member-chain root" do
      # `token.blue` used to translate to bare `token.blue` (NameError at
      # render time). Translation now bails so the caller emits a TODO
      # with the verbatim source, the file loads, and the reviewer sees
      # what to fill in — no NameError, no NoMethodError, no silent flip.
      source = <<~JSX
        function X() {
          const { token } = useToken();
          return <p>{token.blue}</p>;
        }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).not_to include("nil.blue")
      expect(content).not_to match(/plain token\.blue(?!\w)/)
      expect(content).to include("[untranslated: token.blue]")
    end

    it "fails translation for a unary on an unresolvable local (no silent !nil flip)" do
      # `!fieldValue` used to translate to `!nil` (always true), silently
      # flipping the guard's truthiness. Translation now bails so the
      # caller emits a TODO and falls through to the safe fallback.
      source = <<~JSX
        function X() {
          const { fieldValue } = customField;
          return <div>{!fieldValue && <span>missing</span>}</div>;
        }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).not_to match(/^\s*if !nil\s*$/)
      expect(content).to include("# TODO: translate condition: !fieldValue")
      expect(content).to include("if false")
    end

    it "fails translation for a binary on an unresolvable local (no nil > 0)" do
      source = <<~JSX
        function X() {
          const { count } = useStuff();
          return <div>{count > 0 && <span>some</span>}</div>;
        }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).not_to include("nil > 0")
      expect(content).to include("# TODO: translate condition: count > 0")
      expect(content).to include("if false")
    end
  end

  describe "imported-identifier bailout (closes NameError leaks at render time)" do
    it "emits `nil` for a bare reference to a default import" do
      source = <<~JSX
        import CMS_NAME from "@/lib/constants";
        function X() { return <p>{CMS_NAME}</p>; }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).to include("plain nil")
      expect(content).not_to match(/plain cms_name(?!\w)/)
    end

    it "bails out of a member chain whose root is a CSS-module import in an attribute context" do
      # `import styles from "./X.module.css"` plus `data-x={styles.foo}` used
      # to snake-case to a bare `styles.foo` reference that NameErrors at
      # render time. Member-chain root bailout fires now, dropping the
      # attribute with a TODO.
      source = <<~JSX
        import styles from "./Foo.module.css";
        function X() { return <div data-x={styles.foo} />; }
      JSX
      content = file_contents(source, "x.rb")

      # The attribute splices its value through the translator; with bailout,
      # the value can't translate, the kwarg drops entirely, and a TODO
      # surfaces the verbatim JS.
      expect(content).to include('# TODO: attribute "data-x" dropped — couldn\'t translate: styles.foo')
      expect(content).not_to match(/data_x:/)
      # And no executable `styles.foo` reference outside the comment.
      expect(content.lines.reject { |l| l.lstrip.start_with?("#") }.join).not_to include("styles.foo")
    end

    it "bails out of a CSS-module member chain referenced from a JSX child" do
      source = <<~JSX
        import styles from "./Foo.module.css";
        function X() { return <p>{styles.foo}</p>; }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).to include("[untranslated: styles.foo]")
      expect(content.lines.reject { |l| l.lstrip.start_with?("#") }.join).not_to include("plain styles.foo")
    end

    it "bails out of a member chain whose root is a PascalCase namespace import" do
      # TS enum imports referenced in expression context — e.g.
      # `AlertStatusEnum.Pending` — used to snake-case to `alert_status_enum.pending`
      # which NameErrors. Bailout drops the chain with a TODO.
      source = <<~JSX
        import { AlertStatusEnum } from "src/__gql__/graphql";
        function X({ status }) {
          return <div>{status === AlertStatusEnum.Pending && <p>pending</p>}</div>;
        }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).not_to include("alert_status_enum.pending")
      expect(content).to include("# TODO: translate condition: status === AlertStatusEnum.Pending")
    end

    it "bails out when an imported identifier appears as a unary operand" do
      # `!Foo` where Foo is imported used to translate to `!foo` (NameError)
      # or `!Foo` (also NameError under Ruby). The unary-bailout path now
      # fires, the whole expression fails translation, and the caller emits
      # the safe TODO fallback.
      source = <<~JSX
        import { Foo } from "bar";
        function X() {
          return <div>{!Foo && <p>missing</p>}</div>;
        }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).not_to match(/^\s*if !foo\s*$/)
      expect(content).to include("# TODO: translate condition: !Foo")
    end

    it "bails out of a reference to a sibling helper function (not an import)" do
      # `function onError(){}` at module level is captured as a module
      # binding. References from inside the JSX used to NameError as a bare
      # `on_error` ref — the bailout now emits `nil` plus a TODO. The
      # receiving tag here is PascalCase (a component, not an HTML element)
      # so the `onError` reference doesn't get promoted to a Stimulus method.
      source = <<~JSX
        function onError(e) { console.error(e); }
        function X() { return <ErrorBoundary onError={onError}>x</ErrorBoundary>; }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).to match(/on_error: nil/)
      expect(content.lines.reject { |l| l.lstrip.start_with?("#") }.join).not_to match(/on_error: on_error/)
    end

    it "doesn't break translation when an import is shadowed by a local of the same name" do
      # A render-prop parameter named the same as an imported value should
      # take precedence — inside the block, the param resolves locally, not
      # to a bailout. (Edge case worth pinning.)
      source = <<~JSX
        import { fields } from "bar";
        function X() {
          return <Form.List>{(fields) => <p>{fields}</p>}</Form.List>;
        }
      JSX
      content = file_contents(source, "x.rb")

      # Inside the block, `fields` is the param, so the leaf should be
      # `plain fields` — not `plain nil` and not a TODO.
      expect(content).to match(/plain fields(?!\w)/)
    end
  end

  describe "inline arrow handlers on component tags" do
    it "extracts an onClick arrow to a stub `handle_click` method on the class" do
      # Previously dropped to `on_click: nil` + TODO; now the structural
      # attachment is preserved end-to-end via `method(:handle_click)`.
      source = "function X() { return <Button onClick={() => doX()}>save</Button>; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("on_click: method(:handle_click)")
      expect(content).to match(/private\n\n\s+def handle_click\b/)
      expect(content).to include("# TODO: translate the original JSX `onClick` handler:")
      expect(content).to include("doX()")
    end

    it "carries arrow params through to the method signature (snake_cased)" do
      source = "function X() { return <Input onChange={(newValue) => log(newValue)} />; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("on_change: method(:handle_change)")
      expect(content).to include("def handle_change(new_value)")
    end

    it "uses `<attr>_handler` for non-event-style callback prop names" do
      source = "function X() { return <Editor save={(v) => persist(v)} />; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("save: method(:save_handler)")
      expect(content).to include("def save_handler(v)")
    end

    it "preserves the existing bare-identifier passthrough (no new method generated)" do
      # `onClick={onSave}` where onSave is a prop should still emit
      # `on_click: @on_save` — only inline arrows trigger extraction.
      source = "function X({ onSave }) { return <Button onClick={onSave}>x</Button>; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("on_click: @on_save")
      expect(content).not_to include("def handle_click")
    end

    it "preserves event-handler arrows on HTML elements as Stimulus actions (unchanged path)" do
      # Stimulus extraction for HTML-element on* handlers is unrelated and
      # must still fire. This guards against the new EventHandler path
      # accidentally swallowing HTML-event arrows.
      source = "function X() { return <button onClick={() => doX()}>x</button>; }"
      content = file_contents(source, "x.rb")

      expect(content).to match(/data_controller:|data_action:/)
      expect(content).not_to include("on_click: method(:handle_click)")
    end

    it "uniquifies method names across multiple handlers with the same event" do
      source = <<~JSX
        function X() {
          return (
            <>
              <Button onClick={() => a()}>a</Button>
              <Button onClick={() => b()}>b</Button>
            </>
          );
        }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).to include("on_click: method(:handle_click)")
      expect(content).to include("on_click: method(:handle_click2)")
      expect(content).to include("def handle_click")
      expect(content).to include("def handle_click2")
    end
  end

  describe "page-aware class naming" do
    it "skips the configured suffix when the source name ends in `Page`" do
      # `HomePage` + suffix `Component` used to emit `HomePageComponent`
      # — verbose and redundant since `Page` is already a role marker.
      source = "export default function HomePage() { return <p />; }"
      backend = described_class.new(suffix: "Component")
      component = JsxRosetta.lower(source)
      file = backend.emit(component).first

      expect(file.path).to eq("home_page.rb")
      expect(file.contents).to include("class HomePage < Phlex::HTML")
      expect(file.contents).not_to include("HomePageComponent")
    end

    it "treats `/pages/` paths as page sources and appends `Page` (not the configured suffix)" do
      source = "export default function Home() { return <p />; }"
      backend = described_class.new(suffix: "Component")
      component = JsxRosetta.lower(source)
      file = backend.emit(component, source_filename: "app/pages/home.tsx").first

      expect(file.path).to eq("home_page.rb")
      expect(file.contents).to include("class HomePage < Phlex::HTML")
    end

    it "doesn't append `Page` twice for an already-Page-named source under /pages/" do
      source = "export default function HomePage() { return <p />; }"
      backend = described_class.new(suffix: "Component")
      component = JsxRosetta.lower(source)
      file = backend.emit(component, source_filename: "app/pages/HomePage.tsx").first

      expect(file.path).to eq("home_page.rb")
      expect(file.contents).to include("class HomePage < Phlex::HTML")
      expect(file.contents).not_to include("HomePagePage")
    end

    it "keeps the configured suffix for non-page components" do
      source = "export default function Button() { return <button />; }"
      backend = described_class.new(suffix: "Component")
      component = JsxRosetta.lower(source)
      file = backend.emit(component).first

      expect(file.path).to eq("button_component.rb")
      expect(file.contents).to include("class ButtonComponent < Phlex::HTML")
    end

    it "uses the smart-suffix rule for inline component invocations (no double-Page)" do
      # `<HomePage/>` referenced from another component should invoke
      # `HomePage.new`, not `HomePageComponent.new`.
      source = <<~JSX
        export default function App() {
          return <div><HomePage /><Button /></div>;
        }
      JSX
      backend = described_class.new(suffix: "Component")
      component = JsxRosetta.lower(source)
      content = backend.emit(component).first.contents

      expect(content).to include("render HomePage.new")
      expect(content).to include("render ButtonComponent.new")
      expect(content).not_to include("HomePageComponent")
    end

    it "doesn't double a `Component`-named source either" do
      # Same no-double rule, but with the configured `Component` suffix.
      source = "export default function FooComponent() { return <p />; }"
      backend = described_class.new(suffix: "Component")
      component = JsxRosetta.lower(source)
      file = backend.emit(component).first

      expect(file.path).to eq("foo_component.rb")
      expect(file.contents).to include("class FooComponent < Phlex::HTML")
      expect(file.contents).not_to include("FooComponentComponent")
    end
  end

  describe "JSX as attribute value" do
    it "lowers a bare-component JSX value to `ClassRef.new` (no children, no kwargs)" do
      source = "function X() { return <Suspense fallback={<Loading />} />; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("fallback: Loading.new")
    end

    it "preserves kwargs on the inlined component" do
      source = "function X() { return <Button icon={<RightOutlined rotate={90} />} />; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("icon: RightOutlined.new(rotate: 90)")
    end

    it "resolves prop references inside the inlined component" do
      # The JSX value is lowered through the same pipeline as children, so
      # identifier references like `label` resolve to `@label` per the
      # surrounding component's prop scope.
      source = "function X({ label }) { return <Tooltip title={<TooltipBody label={label} />} />; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("title: TooltipBody.new(label: @label)")
    end

    it "unwraps a single-child Fragment around the JSX value" do
      # `<><Foo/></>` is a common idiom for satisfying type checks that
      # require a single ReactNode. Collapse to just the inner child.
      source = "function X() { return <Suspense fallback={<><Loading /></>} />; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("fallback: Loading.new")
      expect(content).not_to include("Fragment")
    end

    it "emits a single-line block for a JSX value with simple children" do
      source = "function X() { return <Tooltip title={<Container><A /><B /></Container>} />; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("title: Container.new { render A.new; render B.new }")
    end

    it "drops to TODO when the JSX value is a plain HTML element (no Phlex receiver context)" do
      # An HTML tag as an attribute value needs the receiver's Phlex render
      # context to execute `span { ... }`. Out of scope for MVP — drop with
      # a TODO so the kwarg stays valid Ruby (`title: nil`) and the source
      # is visible above.
      source = "function X() { return <Tooltip title={<span>hover</span>} />; }"
      content = file_contents(source, "x.rb")

      # Dropped attributes now omit the kwarg entirely; the TODO carries
      # the source.
      expect(content).not_to match(/title:/)
      expect(content).to include("# TODO: attribute \"title\" dropped — couldn't inline JSX value: <span...>")
    end
  end

  describe "empty / dropped kwargs are omitted entirely" do
    it "omits `style:` when every style declaration dropped (no `style: ''` noise)" do
      source = <<~JSX
        import { token } from "antd";
        function X() {
          return <div style={{ padding: token.paddingLG, color: token.colorInfo }} />;
        }
      JSX
      content = file_contents(source, "x.rb")

      # Both style decls drop to TODO above; the kwarg itself is omitted.
      expect(content).to include("# TODO: style declaration \"padding\" dropped")
      expect(content).not_to match(/style:\s*''/)
      expect(content).not_to match(/style:\s*""/)
    end

    it "keeps `style:` when at least one declaration translates" do
      source = <<~JSX
        import { token } from "antd";
        function X() {
          return <div style={{ padding: token.paddingLG, color: "red" }} />;
        }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).to include("color: red;")
      expect(content).to match(/style:/)
    end

    it "omits an attribute whose value bailed to nil with a TODO" do
      # Previously emitted `data_x: nil` plus a TODO. Now the kwarg drops
      # entirely — the TODO above the element is enough.
      source = <<~JSX
        import { token } from "antd";
        function X() {
          return <div data-x={token.foo} />;
        }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).to include("# TODO: attribute \"data-x\" dropped")
      expect(content).not_to match(/data_x:/)
    end

    it "preserves an attribute whose value is an explicit `null` in source" do
      # `data-x={null}` is intentional in JSX — the receiving component
      # might react differently to null vs missing. Translation succeeded
      # (no TODO), so we keep the kwarg.
      source = "function X() { return <div data-x={null} />; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("data_x: nil")
    end
  end

  describe "guard-ladder collapse (closes `if false / elsif false / else` semantic inversion)" do
    it "collapses a chain of untranslatable `return null` guards to a TODO header plus the main render" do
      # PaymentWarning shape: multiple early-return guards with conditions
      # the translator can't model, followed by the happy-path render. The
      # naive emission `if false; ''; elsif false; ''; else <main>` would
      # silently always render `main` — the source semantic was the
      # OPPOSITE. Collapse to a TODO + just the main render so the user
      # sees what guards used to gate it and wires them up Rails-side.
      source = <<~JSX
        import { Alert } from "@mui/material";
        import { useFragment } from "@apollo/client";
        export default function X({ from }) {
          const { complete, data } = useFragment({ from });
          if (!complete) return null;
          if (data.cancelledAt) return null;
          return <Alert>paid</Alert>;
        }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).to include("# TODO: 2 render guard(s) couldn't translate")
      expect(content).to include("#   !complete")
      expect(content).to include("#   data.cancelledAt")
      # No `if false` chain remains.
      expect(content).not_to match(/^\s*if false\b/)
      # The main render is at the same indent as `view_template` body.
      expect(content).to include("render Alert.new")
    end

    it "leaves the chain alone when at least one test translates (we keep the structure)" do
      # Mixed: one translatable condition + one untranslatable. The
      # collapse only fires when EVERY test is untranslatable; otherwise
      # we'd drop a real branch and silently lose behavior.
      source = <<~JSX
        import { useFragment } from "@apollo/client";
        export default function X({ shown }) {
          const { complete } = useFragment({});
          if (!shown) return null;
          if (!complete) return null;
          return <p>x</p>;
        }
      JSX
      content = file_contents(source, "x.rb")

      # `shown` translates to `@shown` (real test), so the chain stays as
      # if/elsif/else and the collapse doesn't fire.
      expect(content).to match(/if !@shown/)
      expect(content).not_to include("render guard(s)")
    end

    it "leaves single-branch conditionals (no else) alone — only ladders with an else collapse" do
      # `cond && <X/>` without an else isn't a guard ladder. The source
      # semantic IS "render the span only when cond is truthy"; an
      # untranslatable cond means we can't replicate that decision. The
      # `if false` form correctly renders nothing as a safe default.
      source = <<~JSX
        import { useFragment } from "@apollo/client";
        export default function X() {
          const { complete } = useFragment({});
          return <div>{complete && <span>x</span>}</div>;
        }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).to include("if false")
      expect(content).not_to include("render guard(s)")
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

      expect(content).to include("['a', 'b'].each do |x|")
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

      expect(content).to include("options: [{ value: 10, data_label: '10 / page' }]")
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

  describe "Data-factory components (AG-Grid column-descriptor module emission)" do
    it "emits a snake_case method that returns the translated array literal" do
      source = <<~JS
        export const createColumns = (token) => [
          { title: "Name", dataIndex: "name", width: 200 }
        ];
      JS
      content = file_contents(source, "create_columns.rb")

      expect(content).to include("class CreateColumns < Phlex::HTML")
      expect(content).to include("def create_columns(token: nil)")
      expect(content).not_to include("def view_template")
      expect(content).not_to include("def initialize")
      expect(content).to include("data_index: 'name'")
    end

    it "extracts JSX render-lambdas inside the data array to private methods" do
      source = <<~JS
        export const createColumns = () => [
          { title: "ID", render: (id) => <span>{id}</span> }
        ];
      JS
      content = file_contents(source, "create_columns.rb")

      expect(content).to include("render: method(:render_render)")
      expect(content).to include("def render_render(id)")
      expect(content).to include("span do")
    end

    it "translates factory param references as locals (bare snake_case, not @ivar)" do
      # `token.colorPrimary` should resolve to `token.color_primary`, not
      # `@token.color_primary` — token is a method-local, not a constructor prop.
      source = <<~JS
        export const createColumns = (token) => [
          { title: "Name", color: token.colorPrimary }
        ];
      JS
      content = file_contents(source, "create_columns.rb")

      expect(content).to include("color: token.color_primary")
      expect(content).not_to include("@token")
    end
  end

  describe "Pretty-printing long object/array literals" do
    # Short literals stay inline (the v0.4.0 behavior). The wrap kicks in
    # only when the single-line rendering exceeds LITERAL_INLINE_BUDGET,
    # so tiny columns/options arrays don't get gratuitously expanded.
    it "keeps short array-of-hash literals inline" do
      content = file_contents(
        "function X() { return <Select options={[{ value: 10, label: \"a\" }]} />; }",
        "x.rb"
      )

      expect(content).to include("options: [{ value: 10, label: 'a' }]")
      # Ensure no spurious wrap.
      expect(content).not_to match(/options: \[\n/)
    end

    it "wraps long array-of-hash literals across multiple lines" do
      source = <<~JS
        function X() {
          return (
            <Grid columns={[
              { field: "name", headerName: "Full Name", sortable: true, filter: true, width: 200 },
              { field: "value", headerName: "Currency Value", sortable: true, filter: false, width: 250 }
            ]} />
          );
        }
      JS
      content = file_contents(source, "x.rb")

      # The wrap puts one element per line at indent+2, with the closing
      # bracket re-aligned to the parent `render` indent (4 spaces for a
      # view_template body) so the file still parses cleanly.
      expect(content).to match(/columns: \[\n      \{/)
      expect(content).to match(/\n    \]/)
      # And the emitted file still passes Ruby syntax check.
      expect(RubyVM::InstructionSequence.compile(content)).to be_a(RubyVM::InstructionSequence)
    end

    it "wraps nested object literals when the outer is wrapped" do
      # When the outer array wraps, the parts come in pre-formatted; nested
      # objects that exceed the inline budget also wrap. The result must
      # still be valid Ruby and the closing brackets must align with the
      # right indent.
      source = <<~JS
        function X() {
          return (
            <Grid columns={[
              { field: "first", config: { sortable: true, filter: true, width: 200, headerCellClass: "long-string-here" } }
            ]} />
          );
        }
      JS
      content = file_contents(source, "x.rb")

      expect(content).to include("config: {")
      expect(content).to include("header_cell_class:")
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

    it "emits the module-bindings TODO only on the first sibling component (no duplication)" do
      # A source file with multiple components used to repeat the same
      # module-level TODO block verbatim in every emitted .rb. Now the
      # first sibling carries it and the rest stay clean.
      source = <<~JSX
        const FOO = 400;
        function A() { return <p>{FOO}</p>; }
        function B() { return <p>{FOO}</p>; }
        function C() { return <p>{FOO}</p>; }
      JSX
      backend = described_class.new
      components = JsxRosetta::IR.lower_all(JsxRosetta.parse(source), source: source)
      files = components.flat_map { |c| backend.emit(c) }
      contents = files.to_h { |f| [f.path, f.contents] }

      expect(contents["a.rb"]).to include("# TODO: module-level constants")
      expect(contents["b.rb"]).not_to include("# TODO: module-level constants")
      expect(contents["c.rb"]).not_to include("# TODO: module-level constants")
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

  describe "Radix primitive → HTML element registry" do
    # Shadcn-style components wrap Radix UI primitives like
    # `<SeparatorPrimitive.Root />` (after `import { Separator as
    # SeparatorPrimitive } from "radix-ui"`). Without a registry, the
    # translator emits `render SeparatorPrimitive::Root.new(...)` which
    # references a non-existent Ruby class — NameError at render. With
    # the registry, known primitives lower as plain HTML elements with
    # always-applied attributes.
    it "lowers <SeparatorPrimitive.Root /> to a <div role=\"separator\">" do
      source = <<~JSX
        import { Separator as SeparatorPrimitive } from "radix-ui";
        function X() {
          return <SeparatorPrimitive.Root orientation="horizontal" />;
        }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).to include("div(role: 'separator', orientation: 'horizontal')")
      expect(content).not_to include("SeparatorPrimitive::Root")
    end

    it "lowers <LabelPrimitive.Root /> to a <label>" do
      # NOTE: htmlFor stays camelCase on lowercase HTML tags — that's the
      # existing Phlex-attribute convention, not specific to this change.
      source = <<~JSX
        import { Label as LabelPrimitive } from "radix-ui";
        function X() { return <LabelPrimitive.Root htmlFor="email">Email</LabelPrimitive.Root>; }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).to include("label(htmlFor: 'email')")
      expect(content).not_to include("LabelPrimitive::Root")
    end

    it "lowers <SwitchPrimitive.Root> to a <button type=\"button\" role=\"switch\">" do
      source = <<~JSX
        import { Switch as SwitchPrimitive } from "radix-ui";
        function X() { return <SwitchPrimitive.Root />; }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).to include("button(type: 'button', role: 'switch')")
    end

    it "respects the consumer's own attribute when it collides with a registry default" do
      # The consumer's `role="dialog"` wins over the registry's `role="separator"`.
      source = <<~JSX
        import { Separator as SeparatorPrimitive } from "radix-ui";
        function X() { return <SeparatorPrimitive.Root role="dialog" />; }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).to include("role: 'dialog'")
      expect(content).not_to include("role: 'separator'")
    end

    it "falls through to ComponentInvocation when the LocalName isn't a Radix import" do
      # Same JSX shape but the import isn't from radix-ui — keep current
      # behavior (renders as Foo::Root component invocation).
      source = <<~JSX
        import { Foo } from "./local-lib";
        function X() { return <Foo.Root />; }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).to include("Foo::Root")
    end

    it "falls through when the (LocalName, Member) pair isn't in the registry" do
      # Imported from radix-ui but `BogusPrimitive.Root` isn't a registered shape.
      source = <<~JSX
        import { Bogus as BogusPrimitive } from "radix-ui";
        function X() { return <BogusPrimitive.Root />; }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).to include("BogusPrimitive::Root")
    end

    it "also matches @radix-ui/react-* per-primitive package paths" do
      # AvatarPrimitive.Root → <span>, even when imported from a per-primitive
      # package (`@radix-ui/react-avatar`) and via a namespace import.
      source = <<~JSX
        import * as AvatarPrimitive from "@radix-ui/react-avatar";
        function X() { return <AvatarPrimitive.Root />; }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).to match(/^    span\s*$/)
      expect(content).not_to include("AvatarPrimitive::Root")
    end
  end

  describe "Lucide icon sidecars (lucide-react imports)" do
    # When a JSX source imports an icon from `lucide-react` and uses it as a
    # component tag, the translator emits sidecar Phlex classes alongside
    # the .rb so the consumer doesn't NameError on `render ChevronRight.new`.
    it "emits per-icon sidecar files for icons referenced in JSX" do
      source = <<~JSX
        import { ChevronRight } from "lucide-react";
        function X() { return <ChevronRight />; }
      JSX
      files = files_for(source)

      expect(files.keys).to include("chevron_right.rb", "lucide_icon.rb")
      expect(files["chevron_right.rb"]).to include("class ChevronRight < LucideIcon")
      expect(files["chevron_right.rb"]).to include("m9 18 6-6-6-6")
      expect(files["lucide_icon.rb"]).to include("class LucideIcon < Phlex::HTML")
    end

    it "honors --phlex-namespace by wrapping icon classes in the same module" do
      source = <<~JSX
        import { Search } from "lucide-react";
        function X() { return <Search />; }
      JSX
      files = files_for(source, namespace: "Components")

      expect(files["search.rb"]).to include("module Components")
      expect(files["search.rb"]).to include("  class Search < LucideIcon")
      expect(files["lucide_icon.rb"]).to include("module Components")
    end

    it "does NOT emit sidecars when a Lucide import is unused in JSX" do
      source = <<~JSX
        import { Star } from "lucide-react";
        function X() { return <div />; }
      JSX
      files = files_for(source)

      expect(files.keys).not_to include("star.rb", "lucide_icon.rb")
    end

    it "does NOT emit sidecars when the import source isn't a Lucide package" do
      source = <<~JSX
        import { ChevronRight } from "react-icons/fi";
        function X() { return <ChevronRight />; }
      JSX
      files = files_for(source)

      expect(files.keys).not_to include("chevron_right.rb", "lucide_icon.rb")
    end

    it "leaves a TODO body when the imported icon isn't in the vendored data" do
      source = <<~JSX
        import { BogusIcon } from "lucide-react";
        function X() { return <BogusIcon />; }
      JSX
      files = files_for(source)

      expect(files["bogus_icon.rb"]).to include("TODO: \"BogusIcon\" isn't in jsx_rosetta's vendored")
      expect(files["bogus_icon.rb"]).to include('def inner_svg = ""')
    end

    it "accepts the legacy *Icon suffix and resolves to the canonical icon" do
      source = <<~JSX
        import { ChevronRightIcon } from "lucide-react";
        function X() { return <ChevronRightIcon />; }
      JSX
      files = files_for(source)

      expect(files["chevron_right_icon.rb"]).to include("class ChevronRightIcon < LucideIcon")
      # Same path data as the canonical ChevronRight.
      expect(files["chevron_right_icon.rb"]).to include("m9 18 6-6-6-6")
    end
  end

  describe "auto-yield on blockless spread-children tags" do
    # The shadcn idiom `<tag {...props} />` (self-closing tag whose rest-spread
    # carries React `children`) lowers to a Phlex tag call with no block, so
    # children that the Phlex caller passes via `Component.new { ... }` were
    # silently dropped. Now we emit a `do; yield if block_given?; end` block
    # for non-void tags when the only thing carrying children is the spread.
    it "wraps a self-closing HTML element that spreads props in a yielding block" do
      source = "function X({ className, ...props }) { return <div className={className} {...props} />; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("div(")
      expect(content).to include("**(@props || {})) do")
      expect(content).to include("yield if block_given?")
    end

    it "does NOT add a yield block to a void HTML element (input)" do
      source = "function X({ type, ...props }) { return <input type={type} {...props} />; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("**(@props || {})")
      expect(content).not_to include("yield")
    end

    it "does NOT add a yield block to a void HTML element (img)" do
      source = "function X({ src, ...props }) { return <img src={src} {...props} />; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("**(@props || {})")
      expect(content).not_to include("yield")
    end

    it "leaves a div with explicit {children} unchanged (existing do/end behavior)" do
      source = "function X({ children, ...props }) { return <div {...props}>{children}</div>; }"
      content = file_contents(source, "x.rb")

      # Explicit children path: do/end with `yield` inside, NOT the safe
      # `yield if block_given?` (existing behavior is unchanged).
      expect(content).to include("div(")
      expect(content).to include(" do")
      expect(content).to match(/^\s+yield$/)
      expect(content).not_to include("yield if block_given?")
    end

    it "wraps a self-closing PascalCase ComponentInvocation that spreads props" do
      source = "function X({ ...rest }) { return <Card {...rest} />; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("render Card.new(**(@rest || {})) do")
      expect(content).to include("yield if block_given?")
    end

    it "does NOT add a yield block when there is no spread (blockless tag stays blockless)" do
      source = "function X() { return <hr />; }"
      content = file_contents(source, "x.rb")

      expect(content).to include("    hr\n  end")
      expect(content).not_to include("yield")
    end

    it "does NOT double-wrap when explicit children are already present" do
      source = "function X({ children, ...rest }) { return <section {...rest}>{children}</section>; }"
      content = file_contents(source, "x.rb")

      # Should yield once (the explicit-children path), not twice.
      expect(content.scan("yield").length).to eq(1)
    end
  end

  describe "inner arrow handlers on PascalCase component props" do
    # `const handleClick = () => ...` attached to a `<PascalCase>` component
    # used to leak as bare `handle_click` (NameError at render time) — Gap B
    # correctly avoided Stimulus promotion for component tags, but the inner
    # arrow was never wired into anything. Lowering now adds unconsumed
    # arrow names to local_binding_names so the use site emits `nil`.
    it "emits nil for an inline-arrow handler bound to a PascalCase component's on*" do
      source = <<~JSX
        function X() {
          const handleClick = () => { foo(); };
          return <CustomButton onClick={handleClick}>Go</CustomButton>;
        }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).to include("on_click: nil")
      expect(content).not_to include("on_click: handle_click")
    end

    it "leaves Stimulus promotion intact for the lowercase HTML case" do
      # Regression check — `<button onClick={handleClick}>` still promotes
      # to a Stimulus method (the Gap B fix is unaffected by the addition).
      source = <<~JSX
        function X() {
          const handleClick = () => { foo(); };
          return <button onClick={handleClick}>Go</button>;
        }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).to match(/data_action: 'click->x#handleClick'/)
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
      expect(content).to include("plain 'Header'")
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

  describe "camelCase rest-prop / aliased-prop ivar matching" do
    # `{ ...descriptionProps }` used to emit `**descriptionProps` in the
    # initializer signature and `@descriptionProps = descriptionProps` for
    # the ivar — but the body referenced `**(@description_props || {})`.
    # The camelCase/snake_case mismatch silently dropped the splat. The
    # initializer kwarg + ivar are now snake_cased to match the body.
    it "snake_cases the rest-prop kwarg and ivar to match the body reference" do
      source = <<~JSX
        function X({ size, ...descriptionProps }) {
          return <Descriptions size={size} {...descriptionProps} />;
        }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).to include("**description_props)")
      expect(content).to include("@description_props = description_props")
      expect(content).to include("**(@description_props || {})")
      expect(content).not_to include("@descriptionProps")
      expect(content).not_to include("**descriptionProps")
    end

    # `"data-testid": dataTestId` binds the prop's value to a renamed
    # local. Use sites of the alias used to leak as bare `data_test_id`
    # (NameError). The translator now resolves the alias to the prop's
    # `@data_testid` ivar.
    it "resolves a renamed prop alias to the prop's ivar" do
      source = <<~JSX
        function X({ "data-testid": dataTestId }) {
          return <FlashyHeader data-testid={dataTestId}>x</FlashyHeader>;
        }
      JSX
      content = file_contents(source, "x.rb")

      expect(content).to include("data_testid: @data_testid")
      expect(content).not_to include("data_test_id")
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

      expect(content).to include("def initialize(label: 'Click')")
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

    it "emits a dedicated Apollo TODO block with the operation name" do
      source = <<~JS
        function X() {
          const { data, loading } = useQuery(GET_USERS_QUERY, { variables: { id } });
          return <p>{loading}</p>;
        }
      JS
      content = file_contents(source, "x.rb")

      expect(content).to include("# TODO: Apollo data-fetching hooks detected")
      expect(content).to include("# Move the fetch to the Rails controller")
      expect(content).to include("#   operation: GET_USERS_QUERY")
      expect(content).to include("useQuery(GET_USERS_QUERY")
      expect(content).not_to include("# TODO: React hooks detected")
    end

    it "emits a dedicated Next.js TODO block for navigation hooks" do
      source = <<~JS
        function X() {
          const router = useRouter();
          const path = usePathname();
          return <p>{path}</p>;
        }
      JS
      content = file_contents(source, "x.rb")

      expect(content).to include("# TODO: Next.js navigation hooks detected")
      expect(content).to include("usePathname -> request.path")
      expect(content).to include("const router = useRouter()")
      expect(content).to include("const path = usePathname()")
      expect(content).not_to include("# TODO: React hooks detected")
    end

    it "emits separate per-library blocks when React + Apollo + Next.js hooks coexist" do
      source = <<~JS
        function X() {
          const [count, setCount] = useState(0);
          const { data } = useQuery(LIST_POSTS);
          const router = useRouter();
          return <p>{count}</p>;
        }
      JS
      content = file_contents(source, "x.rb")

      expect(content).to include("# TODO: React hooks detected")
      expect(content).to include("# TODO: Apollo data-fetching hooks detected")
      expect(content).to include("# TODO: Next.js navigation hooks detected")
      expect(content).to include("#   operation: LIST_POSTS")
    end
  end
end
