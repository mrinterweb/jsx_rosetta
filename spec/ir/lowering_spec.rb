# frozen_string_literal: true

RSpec.describe JsxRosetta::IR::Lowering do
  def lower(source)
    described_class.lower(JsxRosetta.parse(source), source: source)
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

    it "lowers className with an expression to IR::StyleBinding" do
      ir = lower("function X() { return <a className={cn('btn', { active })} />; }")

      style = ir.body.attributes.first
      expect(style).to be_a(JsxRosetta::IR::StyleBinding)
      expect(style.expression).to eq("cn('btn', { active })")
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

    it "lowers a {children} reference to IR::Slot when children is a prop" do
      ir = lower("function X({ children }) { return <p>{children}</p>; }")

      expect(ir.body.children).to eq([JsxRosetta::IR::Slot.new(name: "children")])
    end

    it "leaves {children} as Interpolation when children is not a prop" do
      ir = lower("function X() { return <p>{children}</p>; }")

      expect(ir.body.children).to eq([JsxRosetta::IR::Interpolation.new(expression: "children")])
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
        )
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
      end.to raise_error(JsxRosetta::IR::Lowering::LoweringError)
    end
  end
end
