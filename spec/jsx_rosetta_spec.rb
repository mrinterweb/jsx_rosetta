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

  describe ".translate" do
    it "emits one .rb / .html.erb pair per component (sidecar default layout)" do
      files = described_class.translate("function X() { return <div />; }")

      expect(files.map(&:path)).to contain_exactly(
        "x_component.rb",
        "x_component/x_component.html.erb"
      )
    end

    it "emits one pair per component for multi-component files" do
      source = <<~JSX
        export function Card({ children }) { return <div className="card">{children}</div>; }
        export function CardHeader({ title }) { return <h2>{title}</h2>; }
        export function CardBody({ children }) { return <div>{children}</div>; }
      JSX

      files = described_class.translate(source)

      expect(files.map(&:path)).to contain_exactly(
        "card_component.rb", "card_component/card_component.html.erb",
        "card_header_component.rb", "card_header_component/card_header_component.html.erb",
        "card_body_component.rb", "card_body_component/card_body_component.html.erb"
      )
    end

    it "supports the legacy :flat layout via the layout: kwarg" do
      files = described_class.translate("function X() { return <div />; }", layout: :flat)

      expect(files.map(&:path)).to contain_exactly("x_component.rb", "x_component.html.erb")
    end
  end
end
