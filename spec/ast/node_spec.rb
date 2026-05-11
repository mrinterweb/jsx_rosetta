# frozen_string_literal: true

RSpec.describe JsxRosetta::AST::Node do
  describe ".wrap" do
    it "wraps hashes that have a 'type' key into typed Node subclasses" do
      hash = { "type" => "JSXElement", "openingElement" => nil, "closingElement" => nil, "children" => [] }
      node = described_class.wrap(hash)

      expect(node).to be_a(JsxRosetta::AST::JSXElement)
      expect(node.type).to eq("JSXElement")
    end

    it "leaves hashes without a 'type' key as plain hashes" do
      result = described_class.wrap({ "start" => { "line" => 1 } })
      expect(result).to eq({ "start" => { "line" => 1 } })
    end

    it "wraps arrays element-wise" do
      arr = [{ "type" => "JSXIdentifier", "name" => "a" }, { "type" => "JSXIdentifier", "name" => "b" }]
      result = described_class.wrap(arr)

      expect(result).to all(be_a(JsxRosetta::AST::JSXIdentifier))
      expect(result.map(&:name)).to eq(%w[a b])
    end

    it "falls back to the generic Node for unknown types" do
      node = described_class.wrap({ "type" => "SomeFutureESNextNodeType" })

      expect(node.class).to eq(described_class)
      expect(node.type).to eq("SomeFutureESNextNodeType")
    end
  end

  describe "field access" do
    let(:node) do
      described_class.wrap(
        "type" => "JSXAttribute",
        "name" => { "type" => "JSXIdentifier", "name" => "className" },
        "value" => { "type" => "StringLiteral", "value" => "btn" }
      )
    end

    it "supports snake_case symbol access" do
      expect(node[:name]).to be_a(JsxRosetta::AST::JSXIdentifier)
    end

    it "supports camelCase string access matching Babel field names" do
      expect(node["name"]).to be_a(JsxRosetta::AST::JSXIdentifier)
    end

    it "wraps nested node-shaped values" do
      expect(node[:name].name).to eq("className")
    end
  end

  describe "#walk" do
    it "yields the node itself first, then descends into children depth-first" do
      file = JsxRosetta.parse("const x = <Button />;")

      types = file.walk.map(&:type)
      expect(types.first).to eq("File")
      expect(types).to include("JSXElement", "JSXOpeningElement", "JSXIdentifier")
    end
  end

  describe "#each_child" do
    it "yields immediate node-shaped children only" do
      file = JsxRosetta.parse("const x = <Button />;")

      expect(file.each_child.to_a).to eq([file.program])
    end
  end

  describe "pattern matching via deconstruct_keys" do
    it "exposes snake_case symbol keys for matching" do
      file = JsxRosetta.parse("<Button />")
      jsx_element = file.walk.find { |n| n.is_a?(JsxRosetta::AST::JSXElement) }

      identifier_class = JsxRosetta::AST::JSXIdentifier
      opening_class = JsxRosetta::AST::JSXOpeningElement
      result =
        case jsx_element
        in JsxRosetta::AST::JSXElement(opening_element: ^opening_class => opening)
          case opening.name
          in ^identifier_class => id then id.name
          end
        end

      expect(result).to eq("Button")
    end
  end

  describe "#==" do
    it "compares wrapped raw hashes" do
      a = described_class.wrap({ "type" => "JSXIdentifier", "name" => "x" })
      b = described_class.wrap({ "type" => "JSXIdentifier", "name" => "x" })

      expect(a).to eq(b)
    end
  end

  describe "#child" do
    let(:node) do
      described_class.wrap({
                             "type" => "ExportNamedDeclaration",
                             "declaration" => { "type" => "FunctionDeclaration" },
                             "specifiers" => [],
                             "source" => nil
                           })
    end

    it "returns the wrapped Node when the field is a Node" do
      expect(node.child(:declaration)).to be_a(described_class)
      expect(node.child(:declaration).type).to eq("FunctionDeclaration")
    end

    it "returns nil when the field is missing" do
      expect(node.child(:nonexistent)).to be_nil
    end

    it "returns nil when the field is non-Node-shaped (Array, Hash, String, nil)" do
      expect(node.child(:specifiers)).to be_nil
      expect(node.child(:source)).to be_nil
    end
  end

  describe "#of_type?" do
    let(:node) { described_class.wrap({ "type" => "IfStatement" }) }

    it "is true when type matches" do
      expect(node.of_type?("IfStatement")).to be true
    end

    it "is true when one of multiple types matches" do
      expect(node.of_type?("ReturnStatement", "IfStatement")).to be true
    end

    it "is false when type doesn't match" do
      expect(node.of_type?("ReturnStatement")).to be false
    end
  end

  describe ".matches?" do
    let(:node) { described_class.wrap({ "type" => "IfStatement" }) }

    it "is true for a Node of the given type" do
      expect(described_class.matches?(node, "IfStatement")).to be true
    end

    it "is true when one of multiple types matches" do
      expect(described_class.matches?(node, "ReturnStatement", "IfStatement")).to be true
    end

    it "is false for nil" do
      expect(described_class.matches?(nil, "IfStatement")).to be false
    end

    it "is false for non-Node values (Array, String, Hash)" do
      expect(described_class.matches?([], "IfStatement")).to be false
      expect(described_class.matches?("IfStatement", "IfStatement")).to be false
      expect(described_class.matches?({ "type" => "IfStatement" }, "IfStatement")).to be false
    end

    it "is false for a Node whose type doesn't match" do
      expect(described_class.matches?(node, "ReturnStatement")).to be false
    end
  end
end
