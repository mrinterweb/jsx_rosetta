# frozen_string_literal: true

RSpec.describe JsxRosetta::Parser do
  subject(:parser) { described_class.new }

  describe "#parse" do
    it "returns an AST::File at the root" do
      file = parser.parse("const x = <Button />;")

      expect(file).to be_a(JsxRosetta::AST::File)
      expect(file.program).to be_a(JsxRosetta::AST::Program)
    end

    it "parses the Button fixture and surfaces the JSXElement" do
      file = parser.parse(fixture("jsx", "button.jsx"))

      jsx_element = file.walk.find { |node| node.is_a?(JsxRosetta::AST::JSXElement) }
      expect(jsx_element).not_to be_nil
      expect(jsx_element.tag_name).to eq("button")
    end

    it "preserves source location ranges on nodes" do
      file = parser.parse("<X />")

      jsx_element = file.walk.find { |node| node.is_a?(JsxRosetta::AST::JSXElement) }
      expect(jsx_element.loc.dig("start", "line")).to eq(1)
      expect(jsx_element.range).to be_a(Array)
      expect(jsx_element.start_pos).to eq(0)
    end

    it "parses TSX when typescript: true" do
      tsx = "const x: number = (<Button title='Hi' />) as unknown as number;"
      file = parser.parse(tsx, typescript: true)

      expect(file.walk.find { |n| n.is_a?(JsxRosetta::AST::JSXElement) }).not_to be_nil
    end

    it "raises ParseError with line/column on invalid JSX" do
      parser.parse("const x = <Button>")
    rescue JsxRosetta::ParseError => e
      expect(e.line).to eq(1)
      expect(e.column).to be_a(Integer)
      expect(e.message).to match(/Unexpected token/i)
    else
      raise "expected JsxRosetta::ParseError to be raised"
    end
  end
end
