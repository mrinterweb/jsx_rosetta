# frozen_string_literal: true

RSpec.describe JsxRosetta::Parser do
  subject(:parser) { described_class.new }

  describe "#parse" do
    it "returns a Babel File node at the root" do
      ast = parser.parse("const x = <Button />;")

      expect(ast).to include("type" => "File")
      expect(ast["program"]).to include("type" => "Program")
    end

    it "parses the Button fixture and surfaces the JSXElement" do
      ast = parser.parse(fixture("jsx", "button.jsx"))

      jsx_element = find_first_node(ast, "JSXElement")
      expect(jsx_element).not_to be_nil

      tag_name = jsx_element.dig("openingElement", "name", "name")
      expect(tag_name).to eq("button")
    end

    it "preserves source location ranges on nodes" do
      ast = parser.parse("<X />")

      jsx_element = find_first_node(ast, "JSXElement")
      expect(jsx_element).to include("start", "end", "loc")
      expect(jsx_element.dig("loc", "start", "line")).to eq(1)
    end

    it "parses TSX when typescript: true" do
      tsx = "const x: number = (<Button title='Hi' />) as unknown as number;"
      ast = parser.parse(tsx, typescript: true)

      expect(find_first_node(ast, "JSXElement")).not_to be_nil
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
