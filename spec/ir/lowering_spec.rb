# frozen_string_literal: true

RSpec.describe JsxRosetta::IR::Lowering do
  def lower(source)
    described_class.lower(JsxRosetta.parse(source), source: source)
  end

  describe "key prop" do
    it "drops `key` from a ComponentInvocation's props" do
      ir = lower("function X() { return <Inner key={id} title={t} />; }")

      expect(ir.body).to be_a(JsxRosetta::IR::ComponentInvocation)
      expect(ir.body.props.map { |p| p.respond_to?(:name) ? p.name : nil }).not_to include("key")
      expect(ir.body.props.map { |p| p.respond_to?(:name) ? p.name : nil }).to include("title")
    end

    it "drops `key` on an HTML Element too (React-only hint, not a DOM attribute)" do
      ir = lower("function X() { return <li key={id} />; }")

      expect(ir.body).to be_a(JsxRosetta::IR::Element)
      expect(ir.body.attributes.map(&:name)).not_to include("key")
    end
  end

  describe "html elements vs component invocations" do
    it "lowers a lowercase tag to IR::Element" do
      ir = lower("function X() { return <div />; }")

      expect(ir.body).to eq(JsxRosetta::IR::Element.new(tag: "div", attributes: [], children: []))
    end

    it "lowers a capitalized tag to IR::ComponentInvocation" do
      ir = lower("function X() { return <Button />; }")

      expect(ir.body).to eq(JsxRosetta::IR::ComponentInvocation.new(name: "Button", props: [], children: []))
    end

    it "lowers a member-expression tag to IR::ComponentInvocation" do
      ir = lower("function X() { return <Foo.Bar />; }")

      expect(ir.body).to be_a(JsxRosetta::IR::ComponentInvocation)
      expect(ir.body.name).to eq("Foo.Bar")
    end
  end

  describe "attributes" do
    it "lowers a literal string attribute to a plain Attribute" do
      ir = lower('function X() { return <a href="/about" />; }')

      attr = ir.body.attributes.first
      expect(attr).to eq(JsxRosetta::IR::Attribute.new(name: "href", value: "/about"))
    end

    it "lowers an expression-container attribute to an Interpolation value" do
      ir = lower("function X() { return <a href={url} />; }")

      attr = ir.body.attributes.first
      expect(attr).to eq(
        JsxRosetta::IR::Attribute.new(name: "href", value: JsxRosetta::IR::Interpolation.new(expression: "url"))
      )
    end

    it "lowers a value-less attribute to value: true" do
      ir = lower("function X() { return <input disabled />; }")

      attr = ir.body.attributes.first
      expect(attr).to eq(JsxRosetta::IR::Attribute.new(name: "disabled", value: true))
    end

    it "lowers className to IR::StyleBinding (literal string)" do
      ir = lower('function X() { return <a className="btn primary" />; }')

      style = ir.body.attributes.first
      expect(style).to be_a(JsxRosetta::IR::StyleBinding)
      expect(style.expression).to eq('"btn primary"')
    end

    it "lowers className with a non-helper expression to IR::StyleBinding" do
      ir = lower('function X() { return <a className={ternary ? "a" : "b"} />; }')

      style = ir.body.attributes.first
      expect(style).to be_a(JsxRosetta::IR::StyleBinding)
      expect(style.expression).to eq('ternary ? "a" : "b"')
    end
  end

  describe "children" do
    it "preserves non-whitespace text" do
      ir = lower("function X() { return <p>Hello</p>; }")

      expect(ir.body.children).to eq([JsxRosetta::IR::Text.new(value: "Hello")])
    end

    it "drops pure-whitespace text between siblings" do
      ir = lower("function X() { return <ul>\n  <li />\n  <li />\n</ul>; }")

      expect(ir.body.children.size).to eq(2)
      expect(ir.body.children).to all(be_a(JsxRosetta::IR::Element))
    end

    it "lowers expression-container children to Interpolation" do
      ir = lower("function X() { return <p>{name}</p>; }")

      expect(ir.body.children).to eq([JsxRosetta::IR::Interpolation.new(expression: "name")])
    end

    it "lowers a string-literal expression container to Text" do
      ir = lower('function X() { return <p>a{" "}b</p>; }')

      expect(ir.body.children).to include(JsxRosetta::IR::Text.new(value: " "))
      expect(ir.body.children).not_to include(a_kind_of(JsxRosetta::IR::Interpolation))
    end

    it "lowers a numeric-literal expression container to Text" do
      ir = lower("function X() { return <p>{42}</p>; }")

      expect(ir.body.children).to eq([JsxRosetta::IR::Text.new(value: "42")])
    end

    it "drops boolean-literal and null-literal expression containers" do
      ir = lower("function X() { return <p>{true}{null}{false}</p>; }")

      expect(ir.body.children).to eq([])
    end

    it "lowers a JSX block comment to IR::Comment" do
      ir = lower("function X() { return <p>{/* hello */}</p>; }")

      expect(ir.body.children).to eq([JsxRosetta::IR::Comment.new(text: "hello")])
    end

    it "joins multiple inner comments inside one expression container" do
      ir = lower("function X() { return <p>{/* a */ /* b */}</p>; }")

      expect(ir.body.children.first).to be_a(JsxRosetta::IR::Comment)
      expect(ir.body.children.first.text).to include("a")
      expect(ir.body.children.first.text).to include("b")
    end

    it "lowers a {children} reference to IR::Slot when children is a prop" do
      ir = lower("function X({ children }) { return <p>{children}</p>; }")

      expect(ir.body.children).to eq([JsxRosetta::IR::Slot.new(name: "children")])
    end

    it "leaves {children} as Interpolation when children is not a prop" do
      ir = lower("function X() { return <p>{children}</p>; }")

      expect(ir.body.children).to eq([JsxRosetta::IR::Interpolation.new(expression: "children")])
    end

    it "normalizes JSX whitespace (Babel rules) for inline text with surrounding indentation" do
      ir = lower(<<~JSX)
        function X() {
          return (
            <h3>
              Statically Generated with Next.js.
            </h3>
          );
        }
      JSX

      expect(ir.body.children).to eq([JsxRosetta::IR::Text.new(value: "Statically Generated with Next.js.")])
    end

    it "joins multi-line inline text with single spaces" do
      ir = lower(<<~JSX)
        function X() {
          return (
            <p>
              line one
              line two
            </p>
          );
        }
      JSX

      expect(ir.body.children).to eq([JsxRosetta::IR::Text.new(value: "line one line two")])
    end
  end

  describe "local JSX bindings" do
    it "inlines a `const x = <jsx />` binding when referenced as `{x}`" do
      ir = lower(<<~JSX)
        function X({ src }) {
          const image = <img src={src} />;
          return <div>{image}</div>;
        }
      JSX

      child = ir.body.children.first
      expect(child).to be_a(JsxRosetta::IR::Element)
      expect(child.tag).to eq("img")
    end

    it "inlines a JSX binding into a ternary alternate" do
      ir = lower(<<~JSX)
        function X({ on }) {
          const fallback = <span />;
          return <div>{on ? <strong /> : fallback}</div>;
        }
      JSX

      conditional = ir.body.children.first
      expect(conditional).to be_a(JsxRosetta::IR::Conditional)
      expect(conditional.alternate).to be_a(JsxRosetta::IR::Element)
      expect(conditional.alternate.tag).to eq("span")
    end

    it "leaves a non-JSX local binding's identifier as a bare Interpolation" do
      ir = lower(<<~JSX)
        function X({ raw }) {
          const computed = parse(raw);
          return <p>{computed}</p>;
        }
      JSX

      expect(ir.body.children).to eq([JsxRosetta::IR::Interpolation.new(expression: "computed")])
    end

    it "captures non-JSX local bindings on Component#local_bindings" do
      ir = lower(<<~JSX)
        function X({ raw }) {
          const date = parseISO(raw);
          const total = items.reduce((s, i) => s + i.price, 0);
          return <time>{date}</time>;
        }
      JSX

      expect(ir.local_bindings.map(&:name)).to eq(%w[date total])
      expect(ir.local_bindings.first.source).to eq("const date = parseISO(raw);")
      expect(ir.local_bindings.last.source).to eq("const total = items.reduce((s, i) => s + i.price, 0);")
    end

    it "leaves local_bindings empty when there are no non-JSX bindings" do
      ir = lower("function X() { return <p />; }")

      expect(ir.local_bindings).to eq([])
    end
  end

  describe "event bindings" do
    it "promotes on*={prop} to IR::StimulusBinding (handler name derived from the identifier)" do
      ir = lower("function X({ onClick }) { return <button onClick={onClick} />; }")

      event = ir.body.attributes.first
      expect(event).to be_a(JsxRosetta::IR::StimulusBinding)
      expect(event.event).to eq("click")
      expect(event.method_name).to eq("onClick")
    end

    it "translates onMouseEnter to the native event name and promotes the prop ref" do
      ir = lower("function X({ onMouseEnter }) { return <div onMouseEnter={onMouseEnter} />; }")

      attr = ir.body.attributes.first
      expect(attr).to be_a(JsxRosetta::IR::StimulusBinding)
      expect(attr.event).to eq("mouseenter")
    end

    it "leaves on*=\"literal\" attributes alone (no expression container)" do
      ir = lower('function X() { return <button onClick="alert(1)" />; }')

      expect(ir.body.attributes.first).to be_a(JsxRosetta::IR::Attribute)
    end
  end

  describe "React hook detection" do
    it "captures `const [x, setX] = useState(...)` calls into react_hooks" do
      ir = lower(<<~JSX)
        function X() {
          const [open, setOpen] = useState(false);
          return <div />;
        }
      JSX

      expect(ir.react_hooks.size).to eq(1)
      expect(ir.react_hooks.first.hook).to eq("useState")
      expect(ir.react_hooks.first.source).to include("useState(false)")
    end

    it "captures bare `useEffect(() => {})` expression statements" do
      ir = lower(<<~JSX)
        function X() {
          useEffect(() => { console.log("mounted"); });
          return <div />;
        }
      JSX

      expect(ir.react_hooks.map(&:hook)).to eq(["useEffect"])
    end

    it "captures multiple hooks in source order" do
      ir = lower(<<~JSX)
        function X() {
          const [a, setA] = useState(0);
          const ref = useRef(null);
          const ctx = useContext(MyContext);
          return <div />;
        }
      JSX

      expect(ir.react_hooks.map(&:hook)).to eq(%w[useState useRef useContext])
    end

    it "does not record hook calls in local_bindings (so the human gets one TODO, not two)" do
      ir = lower(<<~JSX)
        function X() {
          const [open, setOpen] = useState(false);
          return <div />;
        }
      JSX

      expect(ir.local_bindings).to eq([])
    end
  end

  describe "polymorphic tag (asChild pattern) synthesis" do
    it "lowers `const C = cond ? Slot : \"button\"; <C {...x}>` to a Conditional" do
      ir = lower(<<~JSX)
        function Button({ asChild, rest }) {
          const Comp = asChild ? Slot.Root : "button";
          return <Comp {...rest}>x</Comp>;
        }
      JSX

      expect(ir.body).to be_a(JsxRosetta::IR::Conditional)
      expect(ir.body.test.expression).to eq("asChild")
      expect(ir.body.consequent).to be_a(JsxRosetta::IR::ComponentInvocation)
      expect(ir.body.consequent.name).to eq("Slot.Root")
      expect(ir.body.alternate).to be_a(JsxRosetta::IR::Element)
      expect(ir.body.alternate.tag).to eq("button")
    end

    it "carries spread props and children through to both branches" do
      ir = lower(<<~JSX)
        function X({ asChild, rest }) {
          const Comp = asChild ? Span : "div";
          return <Comp {...rest}>hi</Comp>;
        }
      JSX

      consequent = ir.body.consequent
      alternate = ir.body.alternate
      expect(consequent.props).to include(JsxRosetta::IR::SpreadAttribute.new(expression: "rest"))
      expect(alternate.attributes).to include(JsxRosetta::IR::SpreadAttribute.new(expression: "rest"))
      expect(consequent.children).to include(JsxRosetta::IR::Text.new(value: "hi"))
      expect(alternate.children).to include(JsxRosetta::IR::Text.new(value: "hi"))
    end

    it "does not record a polymorphic-tag binding in local_bindings (no double TODO)" do
      ir = lower(<<~JSX)
        function X({ asChild }) {
          const Comp = asChild ? Slot : "div";
          return <Comp />;
        }
      JSX

      expect(ir.local_bindings).to eq([])
    end
  end

  describe "Stimulus handler promotion" do
    it "promotes inline arrow handlers to StimulusBinding + StimulusMethod" do
      ir = lower("function X() { return <button onClick={() => doStuff()}>x</button>; }")

      attr = ir.body.attributes.first
      expect(attr).to be_a(JsxRosetta::IR::StimulusBinding)
      expect(attr.event).to eq("click")
      expect(attr.method_name).to eq("clickHandler")
      expect(ir.stimulus_methods.size).to eq(1)
      expect(ir.stimulus_methods.first.name).to eq("clickHandler")
      expect(ir.stimulus_methods.first.body_source).to eq("doStuff()")
    end

    it "promotes a const-bound arrow when referenced as an event handler" do
      ir = lower(<<~JSX)
        function X() {
          const handleClick = () => doStuff();
          return <button onClick={handleClick}>x</button>;
        }
      JSX

      attr = ir.body.attributes.first
      expect(attr).to be_a(JsxRosetta::IR::StimulusBinding)
      expect(attr.method_name).to eq("handleClick")
      expect(ir.stimulus_methods.first.name).to eq("handleClick")
    end

    it "promotes prop-bound event handlers (onClick={propRef}) to Stimulus methods" do
      # A bare prop reference as an event handler has no useful EventBinding
      # rendering — `data-action="<%= @on_click %>"` isn't a valid Stimulus
      # action descriptor. Promoting to Stimulus generates a method whose
      # body documents the original prop reference.
      ir = lower("function X({ onClick }) { return <button onClick={onClick}>x</button>; }")

      attr = ir.body.attributes.first
      expect(attr).to be_a(JsxRosetta::IR::StimulusBinding)
      expect(attr.method_name).to eq("onClick")
      expect(ir.stimulus_methods.first.name).to eq("onClick")
      expect(ir.stimulus_methods.first.body_source).to include("originally bound to: onClick")
    end

    it "uniquifies method names when multiple inline handlers share an event" do
      ir = lower(<<~JSX)
        function X() {
          return (
            <div>
              <button onClick={() => a()}>a</button>
              <button onClick={() => b()}>b</button>
            </div>
          );
        }
      JSX

      method_names = ir.stimulus_methods.map(&:name)
      expect(method_names).to eq(%w[clickHandler clickHandler2])
    end
  end

  describe "conditionals" do
    it "lowers {cond && X} to IR::Conditional with no alternate" do
      ir = lower("function X({ open }) { return <div>{open && <p>shown</p>}</div>; }")

      cond = ir.body.children.first
      expect(cond).to be_a(JsxRosetta::IR::Conditional)
      expect(cond.test).to eq(JsxRosetta::IR::Interpolation.new(expression: "open"))
      expect(cond.consequent).to be_a(JsxRosetta::IR::Element)
      expect(cond.alternate).to be_nil
    end

    it "lowers {cond ? X : null} with no alternate" do
      ir = lower("function X({ open }) { return <div>{open ? <p /> : null}</div>; }")

      cond = ir.body.children.first
      expect(cond.alternate).to be_nil
      expect(cond.consequent).to be_a(JsxRosetta::IR::Element)
    end

    it "lowers {cond ? X : Y} with both branches" do
      ir = lower("function X({ open }) { return <div>{open ? <a /> : <b />}</div>; }")

      cond = ir.body.children.first
      expect(cond.consequent).to be_a(JsxRosetta::IR::Element)
      expect(cond.consequent.tag).to eq("a")
      expect(cond.alternate).to be_a(JsxRosetta::IR::Element)
      expect(cond.alternate.tag).to eq("b")
    end

    it "leaves || and ?? logical expressions as opaque interpolations" do
      ir = lower("function X({ a, b }) { return <div>{a || b}</div>; }")

      expect(ir.body.children.first).to be_a(JsxRosetta::IR::Interpolation)
    end

    it "lowers a top-level ternary return to IR::Conditional" do
      ir = lower("function X({ open }) { return open ? <a /> : <b />; }")

      expect(ir.body).to be_a(JsxRosetta::IR::Conditional)
      expect(ir.body.test).to eq(JsxRosetta::IR::Interpolation.new(expression: "open"))
      expect(ir.body.consequent).to be_a(JsxRosetta::IR::Element)
      expect(ir.body.consequent.tag).to eq("a")
      expect(ir.body.alternate).to be_a(JsxRosetta::IR::Element)
      expect(ir.body.alternate.tag).to eq("b")
    end

    it "lowers a top-level `cond && JSX` return to IR::Conditional with no alternate" do
      ir = lower("function X({ visible }) { return visible && <p />; }")

      expect(ir.body).to be_a(JsxRosetta::IR::Conditional)
      expect(ir.body.alternate).to be_nil
      expect(ir.body.consequent).to be_a(JsxRosetta::IR::Element)
    end

    it "lowers a multi-branch if/else-if/else of all-return branches to a Conditional chain" do
      ir = lower(<<~JS)
        function X({ kind }) {
          if (kind === "a") {
            return <a />;
          } else if (kind === "b") {
            return <b />;
          } else {
            return <c />;
          }
        }
      JS

      cond = ir.body
      expect(cond).to be_a(JsxRosetta::IR::Conditional)
      expect(cond.consequent).to be_a(JsxRosetta::IR::Element)
      expect(cond.consequent.tag).to eq("a")

      else_if = cond.alternate
      expect(else_if).to be_a(JsxRosetta::IR::Conditional)
      expect(else_if.consequent.tag).to eq("b")
      expect(else_if.alternate).to be_a(JsxRosetta::IR::Element)
      expect(else_if.alternate.tag).to eq("c")
    end

    it "lowers a brace-less if/else of bare returns" do
      ir = lower("function X({ open }) { if (open) return <a />; else return <b />; }")

      expect(ir.body).to be_a(JsxRosetta::IR::Conditional)
      expect(ir.body.consequent.tag).to eq("a")
      expect(ir.body.alternate.tag).to eq("b")
    end

    it "silently drops side-effect statements preceding a branch's return (matches outer-block behavior)" do
      jsx = "function X({ kind }) { if (kind) { sideEffect(); return <a />; } else { return <b />; } }"
      ir = lower(jsx)

      expect(ir.body).to be_a(JsxRosetta::IR::Conditional)
      expect(ir.body.consequent.tag).to eq("a")
      expect(ir.body.alternate.tag).to eq("b")
    end
  end

  describe "return shapes (NullLiteral, Identifier, CallExpression)" do
    it "lowers `return null;` to an empty Text node" do
      ir = lower("function X() { return null; }")

      expect(ir.body).to eq(JsxRosetta::IR::Text.new(value: ""))
    end

    it "lowers `if (x) return <A/>; return null;` to a Conditional with empty alternate" do
      ir = lower("function X({ loading }) { if (loading) return <Skeleton />; return null; }")

      expect(ir.body).to be_a(JsxRosetta::IR::Conditional)
      expect(ir.body.consequent).to be_a(JsxRosetta::IR::ComponentInvocation)
      expect(ir.body.consequent.name).to eq("Skeleton")
      expect(ir.body.alternate).to eq(JsxRosetta::IR::Text.new(value: ""))
    end

    it "lowers `return cardIdentifier;` to an Interpolation of the identifier" do
      ir = lower("function X({ card }) { return card; }")

      expect(ir.body).to eq(JsxRosetta::IR::Interpolation.new(expression: "card"))
    end

    it "inlines a JSX-bound local identifier in return position" do
      ir = lower("function X() { const card = <p>hi</p>; return card; }")

      expect(ir.body).to be_a(JsxRosetta::IR::Element)
      expect(ir.body.tag).to eq("p")
    end

    it "lowers `return computeValue(row);` to an Interpolation of the call expression" do
      ir = lower("function X({ row }) { return computeValue(row); }")

      expect(ir.body).to eq(JsxRosetta::IR::Interpolation.new(expression: "computeValue(row)"))
    end

    it "lowers `if (href) return <Link>{children}</Link>; return children;` to a Conditional with Slot alternate" do
      source = "function X({ href, children }) { if (href) return <Link>{children}</Link>; return children; }"
      ir = lower(source)

      expect(ir.body).to be_a(JsxRosetta::IR::Conditional)
      expect(ir.body.consequent).to be_a(JsxRosetta::IR::ComponentInvocation)
      # `children` in return position; @local_jsx isn't set up for params, so it falls through to Interpolation
      expect(ir.body.alternate).to be_a(JsxRosetta::IR::Interpolation)
    end
  end

  describe "switch return chains" do
    it "lowers a switch with bare-return cases and a default to a nested Conditional" do
      ir = lower(<<~JS)
        function X({ kind }) {
          switch (kind) {
            case "a":
              return <a />;
            case "b":
              return <b />;
            default:
              return <c />;
          }
        }
      JS

      cond = ir.body
      expect(cond).to be_a(JsxRosetta::IR::Conditional)
      expect(cond.test.expression).to eq('kind === "a"')
      expect(cond.consequent.tag).to eq("a")

      inner = cond.alternate
      expect(inner).to be_a(JsxRosetta::IR::Conditional)
      expect(inner.test.expression).to eq('kind === "b"')
      expect(inner.consequent.tag).to eq("b")
      expect(inner.alternate.tag).to eq("c")
    end

    it "lowers a switch without a default to a Conditional whose final alternate is empty Text" do
      ir = lower(<<~JS)
        function X({ kind }) {
          switch (kind) {
            case "a":
              return <a />;
          }
        }
      JS

      cond = ir.body
      expect(cond).to be_a(JsxRosetta::IR::Conditional)
      expect(cond.alternate).to eq(JsxRosetta::IR::Text.new(value: ""))
    end

    it "lowers a switch with block-wrapped return cases" do
      ir = lower(<<~JS)
        function X({ kind }) {
          switch (kind) {
            case "a": { return <a />; }
            default: { return <c />; }
          }
        }
      JS

      expect(ir.body).to be_a(JsxRosetta::IR::Conditional)
      expect(ir.body.consequent.tag).to eq("a")
      expect(ir.body.alternate.tag).to eq("c")
    end

    it "ORs the tests for fall-through cases sharing a return value" do
      ir = lower(<<~JS)
        function X({ kind }) {
          switch (kind) {
            case "a":
            case "b":
              return <ab />;
            default:
              return <c />;
          }
        }
      JS

      expect(ir.body.test.expression).to eq('kind === "a" || kind === "b"')
      expect(ir.body.consequent.tag).to eq("ab")
      expect(ir.body.alternate.tag).to eq("c")
    end

    it "silently drops preceding side-effect expressions in a case body (pragmatic match to outer-block behavior)" do
      ir = lower(<<~JS)
        function X({ kind }) {
          switch (kind) {
            case "a":
              sideEffect();
              return <a />;
          }
        }
      JS

      expect(ir.body).to be_a(JsxRosetta::IR::Conditional)
      expect(ir.body.consequent.tag).to eq("a")
    end

    it "raises when a switch case has no return at all (only side effects + break)" do
      jsx = <<~JS
        function X({ kind }) {
          switch (kind) {
            case "a":
              sideEffect();
              break;
          }
        }
      JS
      expect { lower(jsx) }.to raise_error(JsxRosetta::IR::Lowering::LoweringError, /no return statement/)
    end

    it "lowers a case with leading var-decls + return to a Conditional that absorbs the binding" do
      ir = lower(<<~JS)
        function X({ kind, record }) {
          switch (kind) {
            case "money": {
              const money = record.money;
              return <MoneyFormItem money={money} />;
            }
            default: return <p />;
          }
        }
      JS

      expect(ir.body).to be_a(JsxRosetta::IR::Conditional)
      expect(ir.body.consequent).to be_a(JsxRosetta::IR::ComponentInvocation)
      expect(ir.body.consequent.name).to eq("MoneyFormItem")
      expect(ir.local_bindings.map(&:name)).to include("money")
    end

    it "wraps a leading `if (X) return Y;` guard around a trailing switch" do
      ir = lower(<<~JS)
        function X({ value, kind }) {
          if (!value) return <NilValue />;
          switch (kind) {
            case "a": return <a />;
            default: return <b />;
          }
        }
      JS

      expect(ir.body).to be_a(JsxRosetta::IR::Conditional)
      expect(ir.body.test.expression).to eq("!value")
      expect(ir.body.consequent).to be_a(JsxRosetta::IR::ComponentInvocation)
      expect(ir.body.consequent.name).to eq("NilValue")
      expect(ir.body.alternate).to be_a(JsxRosetta::IR::Conditional)
    end
  end

  describe "try return chains" do
    it "lowers a `try { return <X/>; }` to the try block's return value" do
      ir = lower(<<~JS)
        function X() {
          try {
            return <a />;
          } catch (e) {
            console.error(e);
          }
        }
      JS

      expect(ir.body).to be_a(JsxRosetta::IR::Element)
      expect(ir.body.tag).to eq("a")
    end

    it "raises when the try block has no recognizable return" do
      jsx = "function X() { try { sideEffect(); } catch (e) {} }"
      expect { lower(jsx) }.to raise_error(JsxRosetta::IR::Lowering::LoweringError, /no return statement/)
    end
  end

  describe "module-shape classifier (error-message UX)" do
    it "labels a hooks-only module with a behavior-vs-state hint" do
      expect { lower("export function useThing() { const [s, setS] = useState(0); return s; }") }
        .to raise_error(JsxRosetta::IR::Lowering::LoweringError, /custom-hooks module.*Stimulus controller/)
    end

    it "labels a utility module that has no JSX-returning helpers" do
      expect { lower("export function formatThing(x) { return x.toString(); }") }
        .to raise_error(JsxRosetta::IR::Lowering::LoweringError, /utility module.*JSX-returning/)
    end

    it "labels a class-component module" do
      expect { lower("export class MyComp extends React.Component { render() { return <div />; } }") }
        .to raise_error(JsxRosetta::IR::Lowering::LoweringError, /class component.*function components/)
    end

    it "labels a columns/data module (top-level array literal export)" do
      expect { lower("export const columns = [{ title: 'Name' }, { title: 'Age' }];") }
        .to raise_error(JsxRosetta::IR::Lowering::LoweringError, /data export.*not a component/)
    end

    it "labels a HOC-wrapped component" do
      expect { lower("export const X = React.memo(function X() { return foo; });") }
        .to raise_error(JsxRosetta::IR::Lowering::LoweringError, /HOC-wrapped component/)
    end

    it "labels a types-only module" do
      source = "export type Foo = { a: 1 };"
      ast = JsxRosetta.parse(source, typescript: true)
      expect { JsxRosetta::IR::Lowering.lower(ast, source: source) }
        .to raise_error(JsxRosetta::IR::Lowering::LoweringError, %r{types/constants module})
    end

    it "labels a mixed-exports module (some hooks + some non-hook helpers)" do
      source = <<~JS
        export const splitExtension = (s) => s.split(".");
        export const useFilenameEditor = ({}) => { return ""; };
      JS
      expect { lower(source) }.to raise_error(JsxRosetta::IR::Lowering::LoweringError, /mixes shapes/)
    end

    it "leaves the suffix off when nothing matches" do
      expect { lower("import x from 'y';") }
        .to raise_error(JsxRosetta::IR::Lowering::LoweringError) do |error|
          expect(error.message).not_to include("looks like a")
          expect(error.message).to include("no component function found in module")
        end
    end
  end

  describe "lowercase-named JSX-returning helpers" do
    it "treats a lowercase function whose body returns JSX as a component" do
      ir = lower("export const textRender = (value) => { if (!value) return value; return <NilValue />; };")

      expect(ir).to be_a(JsxRosetta::IR::Component)
      expect(ir.name).to eq("textRender")
    end

    it "treats a lowercase function with implicit JSX return as a component" do
      ir = lower("export const renderTag = () => <Tag />;")

      expect(ir).to be_a(JsxRosetta::IR::Component)
      expect(ir.name).to eq("renderTag")
      expect(ir.body).to be_a(JsxRosetta::IR::ComponentInvocation)
    end

    it "lifts a switch-with-JSX-cases lowercase function as a component" do
      ir = lower(<<~JS)
        export const cellFor = (kind) => {
          switch (kind) {
            case "name": return <NameCell />;
            default: return <DefaultCell />;
          }
        };
      JS

      expect(ir).to be_a(JsxRosetta::IR::Component)
      expect(ir.body).to be_a(JsxRosetta::IR::Conditional)
    end

    it "still rejects a lowercase function whose body returns no JSX" do
      expect { lower("export const formatThing = (x) => x.toString();") }
        .to raise_error(JsxRosetta::IR::Lowering::LoweringError, /no component function found/)
    end

    it "still rejects a `use*` hook even when the hook body would technically render JSX" do
      # Defensive: prevents accidental component-translation of hooks whose
      # name signals they return data, not view markup.
      expect { lower("export const useThing = () => <p />;") }
        .to raise_error(JsxRosetta::IR::Lowering::LoweringError, /no component function found/)
    end

    it "lowers a multi-helper file picking the first JSX-returning one" do
      source = <<~JS
        export const textRender = (v) => v ? v : <NilValue />;
        export const booleanRender = (v) => v ? "Yes" : <NilValue />;
      JS
      ir = lower(source)

      expect(ir).to be_a(JsxRosetta::IR::Component)
      expect(ir.name).to eq("textRender")
    end
  end

  describe "return shapes — non-JSX expressions" do
    it "lowers `return memberExpr;` to an Interpolation of the verbatim source" do
      ir = lower("function X({ money }) { return money.formattedValue; }")

      expect(ir.body).to eq(JsxRosetta::IR::Interpolation.new(expression: "money.formattedValue"))
    end

    it "lowers `return 'literal';` to Text" do
      ir = lower("function X() { return 'hello'; }")

      expect(ir.body).to eq(JsxRosetta::IR::Text.new(value: "hello"))
    end

    it "lowers `return 42;` to Text of the stringified number" do
      ir = lower("function X() { return 42; }")

      expect(ir.body).to eq(JsxRosetta::IR::Text.new(value: "42"))
    end

    it "lowers `return template literals` to Interpolation" do
      ir = lower("function X({ name }) { return `hello ${name}`; }")

      expect(ir.body).to be_a(JsxRosetta::IR::Interpolation)
    end
  end

  describe "loops" do
    it "lowers items.map((item) => <X />) to IR::Loop" do
      ir = lower("function X({ items }) { return <ul>{items.map((item) => <li />)}</ul>; }")

      loop_node = ir.body.children.first
      expect(loop_node).to be_a(JsxRosetta::IR::Loop)
      expect(loop_node.iterable).to eq(JsxRosetta::IR::Interpolation.new(expression: "items"))
      expect(loop_node.item_binding).to eq("item")
      expect(loop_node.index_binding).to be_nil
      expect(loop_node.body).to be_a(JsxRosetta::IR::Element)
      expect(loop_node.body.tag).to eq("li")
    end

    it "captures the index binding when present" do
      ir = lower("function X({ items }) { return <ul>{items.map((item, i) => <li />)}</ul>; }")

      expect(ir.body.children.first.index_binding).to eq("i")
    end

    it "supports a block-bodied arrow function with a return" do
      jsx = "function X({ items }) { return <ul>{items.map((item) => { return <li />; })}</ul>; }"
      ir = lower(jsx)

      expect(ir.body.children.first).to be_a(JsxRosetta::IR::Loop)
    end

    it "leaves non-map call expressions as opaque interpolations" do
      ir = lower("function X({ items }) { return <p>{items.length}</p>; }")

      expect(ir.body.children.first).to be_a(JsxRosetta::IR::Interpolation)
    end
  end

  describe "fragments" do
    it "lowers a JSX fragment to IR::Fragment" do
      ir = lower("function X() { return <><Button /></>; }")

      expect(ir.body).to be_a(JsxRosetta::IR::Fragment)
      expect(ir.body.children.first).to be_a(JsxRosetta::IR::ComponentInvocation)
    end
  end

  describe "props" do
    it "lowers destructured props with no defaults" do
      ir = lower("function X({ a, b }) { return <div />; }")

      expect(ir.props).to eq([
                               JsxRosetta::IR::Prop.new(name: "a", default: nil),
                               JsxRosetta::IR::Prop.new(name: "b", default: nil)
                             ])
    end

    it "lowers destructured props with defaults to Interpolation defaults" do
      ir = lower('function X({ variant = "primary", size = 4 }) { return <div />; }')

      expect(ir.props).to eq([
                               JsxRosetta::IR::Prop.new(
                                 name: "variant",
                                 default: JsxRosetta::IR::Interpolation.new(expression: '"primary"')
                               ),
                               JsxRosetta::IR::Prop.new(
                                 name: "size",
                                 default: JsxRosetta::IR::Interpolation.new(expression: "4")
                               )
                             ])
    end

    it "lowers a single-identifier params bag" do
      ir = lower("function X(props) { return <div />; }")

      expect(ir.props).to eq([JsxRosetta::IR::Prop.new(name: "props", default: nil)])
    end

    it "captures the rest-binding name into rest_prop_name and excludes it from props" do
      ir = lower("function X({ a, ...rest }) { return <div />; }")

      expect(ir.props).to eq([JsxRosetta::IR::Prop.new(name: "a", default: nil)])
      expect(ir.rest_prop_name).to eq("rest")
    end

    it "leaves rest_prop_name nil when there is no rest binding" do
      ir = lower("function X({ a }) { return <div />; }")

      expect(ir.rest_prop_name).to be_nil
    end

    it "lowers a nested-destructured prop using the outer key as the prop name" do
      ir = lower("function X({ record: { claimNumber, claim }, accountSlug }) { return <div />; }")

      expect(ir.props).to eq([
                               JsxRosetta::IR::Prop.new(name: "record", default: nil),
                               JsxRosetta::IR::Prop.new(name: "accountSlug", default: nil)
                             ])
    end

    it "lowers a renamed-destructured prop using the source-side key" do
      ir = lower("function X({ outer: inner }) { return <div />; }")

      expect(ir.props).to eq([JsxRosetta::IR::Prop.new(name: "outer", default: nil)])
    end

    it "lowers a StringLiteral destructure key (e.g. `data-testid`)" do
      ir = lower('function X({ "data-testid": testId }) { return <div data-testid={testId} />; }')

      expect(ir.props).to eq([JsxRosetta::IR::Prop.new(name: "data-testid", default: nil)])
    end

    it "lowers a StringLiteral destructure key with a default" do
      ir = lower('function X({ "data-testid": testId = "x" }) { return <div />; }')

      expect(ir.props).to eq([
                               JsxRosetta::IR::Prop.new(
                                 name: "data-testid",
                                 default: JsxRosetta::IR::Interpolation.new(expression: '"x"')
                               )
                             ])
    end

    it "round-trips a StringLiteral destructure key through the backend as a snake_case kwarg" do
      source = 'function FlashyHeader({ "data-testid": dataTestId }) { return <h1 data-testid={dataTestId}>x</h1>; }'
      backend = JsxRosetta::Backend::ViewComponent.new(layout: :flat)
      files = backend.emit(lower(source)).to_h { |f| [f.path, f.contents] }

      expect(files["flashy_header_component.rb"]).to include("data_testid: nil")
      expect(files["flashy_header_component.rb"]).to include("@data_testid = data_testid")
      expect(files["flashy_header_component.html.erb"]).to include("data-testid=")
    end
  end

  describe "cn / clsx className lowering" do
    it "lowers `className={cn(\"a\", \"b\")}` to a ClassList of literal segments" do
      ir = lower('function X() { return <div className={cn("a", "b")} />; }')

      expect(ir.body.attributes).to eq([JsxRosetta::IR::ClassList.new(segments: %w[a b])])
    end

    it "lowers identifier arguments to IR::Interpolation segments" do
      ir = lower("function X({ extra }) { return <div className={cn(\"base\", extra)} />; }")

      class_list = ir.body.attributes.first
      expect(class_list).to be_a(JsxRosetta::IR::ClassList)
      expect(class_list.segments).to eq([
                                          "base",
                                          JsxRosetta::IR::Interpolation.new(expression: "extra")
                                        ])
    end

    it "lowers object-literal arguments to ConditionalSegment entries" do
      ir = lower('function X({ on }) { return <div className={cn("base", { "active": on, "done": !on })} />; }')

      class_list = ir.body.attributes.first
      expect(class_list).to be_a(JsxRosetta::IR::ClassList)
      expect(class_list.segments[1]).to eq(
        JsxRosetta::IR::ConditionalSegment.new(
          class_name: "active",
          condition: JsxRosetta::IR::Interpolation.new(expression: "on")
        )
      )
      expect(class_list.segments[2]).to eq(
        JsxRosetta::IR::ConditionalSegment.new(
          class_name: "done",
          condition: JsxRosetta::IR::Interpolation.new(expression: "!on")
        )
      )
    end

    it "recognizes clsx and classnames callers as well" do
      ir = lower('function X() { return <div className={clsx("a")} />; }')
      expect(ir.body.attributes.first).to be_a(JsxRosetta::IR::ClassList)

      ir = lower('function X() { return <div className={classnames("a")} />; }')
      expect(ir.body.attributes.first).to be_a(JsxRosetta::IR::ClassList)
    end

    it "falls back to StyleBinding when an argument shape is unsupported" do
      ir = lower('function X() { return <div className={cn("a", computeOther())} />; }')

      expect(ir.body.attributes.first).to be_a(JsxRosetta::IR::StyleBinding)
    end
  end

  describe "inline styles" do
    it "lowers `style={{ fontSize: 12, color: \"red\" }}` to IR::Style" do
      ir = lower('function X() { return <div style={{ fontSize: 12, color: "red" }} />; }')

      expect(ir.body.attributes).to eq([
                                         JsxRosetta::IR::Style.new(
                                           declarations: [
                                             JsxRosetta::IR::StyleDeclaration.new(property: "font-size", value: "12"),
                                             JsxRosetta::IR::StyleDeclaration.new(property: "color", value: "red")
                                           ]
                                         )
                                       ])
    end

    it "lowers identifier values to IR::Interpolation in StyleDeclaration" do
      ir = lower("function X({ size }) { return <div style={{ fontSize: size }} />; }")

      decl = ir.body.attributes.first.declarations.first
      expect(decl.property).to eq("font-size")
      expect(decl.value).to eq(JsxRosetta::IR::Interpolation.new(expression: "size"))
    end

    it "falls back to a plain Attribute when an inline-style value shape is unsupported" do
      ir = lower("function X() { return <div style={{ fontSize: computeSize() }} />; }")

      expect(ir.body.attributes.first).to be_a(JsxRosetta::IR::Attribute)
      expect(ir.body.attributes.first.name).to eq("style")
    end
  end

  describe "spread attributes" do
    it "lowers `{...rest}` to IR::SpreadAttribute on an Element" do
      ir = lower("function X({ rest }) { return <div {...rest} />; }")

      expect(ir.body.attributes).to eq([JsxRosetta::IR::SpreadAttribute.new(expression: "rest")])
    end

    it "lowers `{...rest}` to IR::SpreadAttribute on a ComponentInvocation" do
      ir = lower("function X({ rest }) { return <Inner {...rest} />; }")

      expect(ir.body.props).to eq([JsxRosetta::IR::SpreadAttribute.new(expression: "rest")])
    end
  end

  describe "exported components" do
    it "finds a function inside an ExportNamedDeclaration" do
      ir = lower("export function Greeting() { return <p>Hi</p>; }")

      expect(ir.name).to eq("Greeting")
    end

    it "finds a function inside an ExportDefaultDeclaration" do
      ir = lower("export default function Greeting() { return <p>Hi</p>; }")

      expect(ir.name).to eq("Greeting")
    end
  end

  describe "skipping non-component top-level functions" do
    it "skips lowercase-named functions (React convention: hooks are camelCase, helpers lowercase)" do
      source = <<~JSX
        function useCarousel() { return context; }
        function Carousel({ children }) { return <div>{children}</div>; }
      JSX

      ir = JsxRosetta::IR.lower_all(JsxRosetta.parse(source), source: source)
      expect(ir.map(&:name)).to eq(["Carousel"])
    end

    it "skips lowercase const-bound arrows alongside PascalCase ones" do
      source = <<~JSX
        const useFormField = () => ({});
        const Form = () => <form />;
      JSX

      ir = JsxRosetta::IR.lower_all(JsxRosetta.parse(source), source: source)
      expect(ir.map(&:name)).to eq(["Form"])
    end
  end

  describe "arrow-function components" do
    it "lowers `const X = () => { return <jsx>; }`" do
      ir = lower("const Greeting = () => { return <p>Hi</p>; };")

      expect(ir.name).to eq("Greeting")
      expect(ir.body.tag).to eq("p")
    end

    it "lowers `const X = () => <jsx>` (implicit return)" do
      ir = lower("const Greeting = () => <p>Hi</p>;")

      expect(ir.name).to eq("Greeting")
      expect(ir.body.tag).to eq("p")
    end

    it "lowers an exported arrow-function component" do
      ir = lower("export const Greeting = ({ who }) => <p>Hi {who}</p>;")

      expect(ir.name).to eq("Greeting")
      expect(ir.props.map(&:name)).to eq(["who"])
    end

    it "lowers a function-expression assigned to a const" do
      ir = lower("const Greeting = function () { return <p>Hi</p>; };")

      expect(ir.name).to eq("Greeting")
    end
  end

  describe "Button fixture (full IR equality)" do
    it "lowers the Button fixture to the expected IR tree" do
      source = File.read(File.expand_path("../fixtures/jsx/button.jsx", __dir__))

      ir = described_class.lower(JsxRosetta.parse(source), source: source)

      expected = JsxRosetta::IR::Component.new(
        name: "Button",
        props: [
          JsxRosetta::IR::Prop.new(name: "children", default: nil),
          JsxRosetta::IR::Prop.new(name: "onClick", default: nil),
          JsxRosetta::IR::Prop.new(
            name: "variant",
            default: JsxRosetta::IR::Interpolation.new(expression: '"primary"')
          )
        ],
        body: JsxRosetta::IR::Element.new(
          tag: "button",
          attributes: [
            JsxRosetta::IR::Attribute.new(name: "type", value: "button"),
            JsxRosetta::IR::StyleBinding.new(expression: "`btn btn-${variant}`"),
            JsxRosetta::IR::StimulusBinding.new(event: "click", method_name: "onClick")
          ],
          children: [
            JsxRosetta::IR::Slot.new(name: "children")
          ]
        ),
        rest_prop_name: nil,
        local_bindings: [],
        stimulus_methods: [
          JsxRosetta::IR::StimulusMethod.new(name: "onClick", body_source: "// originally bound to: onClick")
        ],
        react_hooks: []
      )

      expect(ir).to eq(expected)
    end
  end

  describe "errors" do
    it "raises a LoweringError when there is no component function" do
      expect { lower("const x = 1;") }.to raise_error(JsxRosetta::IR::Lowering::LoweringError)
    end

    it "raises a LoweringError when the function has no return statement" do
      expect do
        lower("function X() { console.log('hi'); }")
      end.to raise_error(JsxRosetta::IR::Lowering::LoweringError, /line \d+/)
    end

    it "includes line and column on the error when a node anchors the failure" do
      source = "function X(...weird) {\n  return <p />;\n}"
      expect { described_class.lower(JsxRosetta.parse(source), source: source) }
        .to raise_error(JsxRosetta::IR::Lowering::LoweringError) do |error|
          expect(error.line).to eq(1)
          expect(error.column).to be > 0
          expect(error.message).to match(/line 1, column \d+/)
        end
    end
  end
end
