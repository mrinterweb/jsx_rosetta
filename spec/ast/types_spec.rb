# frozen_string_literal: true

RSpec.describe "JsxRosetta::AST typed nodes" do
  let(:button_file) { JsxRosetta.parse(File.read(File.expand_path("../fixtures/jsx/button.jsx", __dir__))) }

  describe JsxRosetta::AST::File do
    it "exposes the program" do
      expect(button_file.program).to be_a(JsxRosetta::AST::Program)
    end
  end

  describe JsxRosetta::AST::Program do
    it "exposes the body as wrapped nodes" do
      body = button_file.program.body
      expect(body).to be_a(Array)
      expect(body).to all(be_a(JsxRosetta::AST::Node))
      expect(body.map(&:type)).to include("ImportDeclaration", "ExportNamedDeclaration")
    end

    it "exposes the source type" do
      expect(button_file.program.source_type).to eq("module")
    end
  end

  describe JsxRosetta::AST::JSXElement do
    let(:button_element) do
      button_file.walk.find { |n| n.is_a?(JsxRosetta::AST::JSXElement) }
    end

    it "exposes the opening and closing elements" do
      expect(button_element.opening_element).to be_a(JsxRosetta::AST::JSXOpeningElement)
      expect(button_element.closing_element).to be_a(JsxRosetta::AST::JSXClosingElement)
    end

    it "reports its tag name" do
      expect(button_element.tag_name).to eq("button")
    end

    it "knows whether it is self-closing" do
      expect(button_element).not_to be_self_closing

      file = JsxRosetta.parse("const x = <Icon />;")
      icon = file.walk.find { |n| n.is_a?(JsxRosetta::AST::JSXElement) }
      expect(icon).to be_self_closing
    end

    it "exposes JSX children (attributes are not children)" do
      jsx_children = button_element.jsx_children
      expect(jsx_children).to all(be_a(JsxRosetta::AST::Node))
      expect(jsx_children.map(&:type)).to include("JSXExpressionContainer")
    end
  end

  describe JsxRosetta::AST::JSXOpeningElement do
    it "exposes its attributes as wrapped nodes" do
      file = JsxRosetta.parse('const x = <a href="/" target="_blank" />;')
      opening = file.walk.find { |n| n.is_a?(JsxRosetta::AST::JSXOpeningElement) }

      expect(opening.attributes.map(&:type)).to eq(%w[JSXAttribute JSXAttribute])
      expect(opening.attributes.map(&:attribute_name)).to eq(%w[href target])
    end

    it "resolves member-expression tag names" do
      file = JsxRosetta.parse("const x = <Foo.Bar.Baz />;")
      element = file.walk.find { |n| n.is_a?(JsxRosetta::AST::JSXElement) }

      expect(element.tag_name).to eq("Foo.Bar.Baz")
    end

    it "resolves namespaced tag names" do
      file = JsxRosetta.parse("const x = <svg:rect />;")
      element = file.walk.find { |n| n.is_a?(JsxRosetta::AST::JSXElement) }

      expect(element.tag_name).to eq("svg:rect")
    end
  end

  describe JsxRosetta::AST::JSXAttribute do
    it "reports its attribute name and value" do
      file = JsxRosetta.parse('const x = <a href="/about" />;')
      attribute = file.walk.find { |n| n.is_a?(JsxRosetta::AST::JSXAttribute) }

      expect(attribute.attribute_name).to eq("href")
      expect(attribute.value.type).to eq("StringLiteral")
      expect(attribute.value[:value]).to eq("/about")
    end

    it "wraps expression-container values" do
      file = JsxRosetta.parse("const x = <a href={url} />;")
      attribute = file.walk.find { |n| n.is_a?(JsxRosetta::AST::JSXAttribute) }

      expect(attribute.value).to be_a(JsxRosetta::AST::JSXExpressionContainer)
      expect(attribute.value.expression.type).to eq("Identifier")
    end
  end

  describe JsxRosetta::AST::JSXFragment do
    it "exposes opening/closing fragment markers and children" do
      file = JsxRosetta.parse("const x = <><Button /></>;")
      fragment = file.walk.find { |n| n.is_a?(JsxRosetta::AST::JSXFragment) }

      expect(fragment.opening_fragment).to be_a(JsxRosetta::AST::JSXOpeningFragment)
      expect(fragment.closing_fragment).to be_a(JsxRosetta::AST::JSXClosingFragment)
      expect(fragment.jsx_children.first).to be_a(JsxRosetta::AST::JSXElement)
    end
  end
end
