# frozen_string_literal: true

RSpec.describe JsxRosetta do
  it "has a version number" do
    expect(JsxRosetta::VERSION).not_to be_nil
  end

  describe ".parse" do
    it "delegates to Parser and returns a typed AST::File" do
      file = described_class.parse("const x = <Button />;")

      expect(file).to be_a(JsxRosetta::AST::File)
      expect(file.type).to eq("File")
    end
  end
end
