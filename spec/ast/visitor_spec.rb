# frozen_string_literal: true

RSpec.describe JsxRosetta::AST::Visitor do
  let(:button_file) do
    JsxRosetta.parse(File.read(File.expand_path("../fixtures/jsx/button.jsx", __dir__)))
  end

  describe "default behavior" do
    it "recurses through every node when no handlers are defined" do
      counter_class = Class.new(described_class) do
        attr_reader :count

        def initialize
          super
          @count = 0
        end

        def visit_default(node)
          @count += 1
          super
        end
      end

      counter = counter_class.new
      counter.visit(button_file)

      expected_count = button_file.walk.count
      expect(counter.count).to eq(expected_count)
    end
  end

  describe "type-specific handlers" do
    it "dispatches to visit_jsx_element for every JSXElement and stops recursing if visit_children is not called" do
      collector_class = Class.new(described_class) do
        attr_reader :tag_names

        def initialize
          super
          @tag_names = []
        end

        def visit_jsx_element(node)
          @tag_names << node.tag_name
          visit_children(node)
        end
      end

      collector = collector_class.new
      collector.visit(button_file)

      expect(collector.tag_names).to include("button")
    end

    it "still calls visit_default for unhandled node types" do
      tracker_class = Class.new(described_class) do
        attr_reader :unhandled_types

        def initialize
          super
          @unhandled_types = []
        end

        def visit_default(node)
          @unhandled_types << node.type
          super
        end

        def visit_jsx_element(node)
          visit_children(node)
        end
      end

      tracker = tracker_class.new
      tracker.visit(button_file)

      expect(tracker.unhandled_types).to include("File", "Program", "FunctionDeclaration", "JSXIdentifier")
      expect(tracker.unhandled_types).not_to include("JSXElement")
    end
  end
end
