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
    it "lowers on*={prop} to IR::EventBinding with the lowercased event name" do
      ir = lower("function X({ onClick }) { return <button onClick={onClick} />; }")

      event = ir.body.attributes.first
      expect(event).to eq(
        JsxRosetta::IR::EventBinding.new(
          event: "click",
          handler: JsxRosetta::IR::Interpolation.new(expression: "onClick")
        )
      )
    end

    it "translates onMouseEnter to the native event name" do
      ir = lower("function X({ onMouseEnter }) { return <div onMouseEnter={onMouseEnter} />; }")

      expect(ir.body.attributes.first.event).to eq("mouseenter")
    end

    it "leaves on*=\"literal\" attributes alone (no expression container)" do
      ir = lower('function X() { return <button onClick="alert(1)" />; }')

      expect(ir.body.attributes.first).to be_a(JsxRosetta::IR::Attribute)
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

    it "leaves prop-bound event handlers as EventBinding (no Stimulus promotion)" do
      ir = lower("function X({ onClick }) { return <button onClick={onClick}>x</button>; }")

      attr = ir.body.attributes.first
      expect(attr).to be_a(JsxRosetta::IR::EventBinding)
      expect(ir.stimulus_methods).to eq([])
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
            JsxRosetta::IR::EventBinding.new(
              event: "click",
              handler: JsxRosetta::IR::Interpolation.new(expression: "onClick")
            )
          ],
          children: [
            JsxRosetta::IR::Slot.new(name: "children")
          ]
        ),
        rest_prop_name: nil,
        local_bindings: [],
        stimulus_methods: []
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
