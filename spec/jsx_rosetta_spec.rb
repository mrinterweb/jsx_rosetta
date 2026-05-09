# frozen_string_literal: true

RSpec.describe JsxRosetta do
  it "has a version number" do
    expect(JsxRosetta::VERSION).not_to be_nil
  end

  describe ".parse" do
    it "delegates to Parser and returns the parsed AST" do
      ast = described_class.parse("const x = <Button />;")

      expect(ast).to be_a(Hash)
      expect(ast["type"]).to eq("File")
    end
  end
end
