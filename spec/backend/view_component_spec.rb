# frozen_string_literal: true

RSpec.describe JsxRosetta::Backend::ViewComponent do
  subject(:backend) { described_class.new }

  def files_for(jsx_source)
    component = JsxRosetta.lower(jsx_source)
    backend.emit(component).to_h { |file| [file.path, file.contents] }
  end

  describe "Button fixture (end-to-end golden test)" do
    let(:source) { File.read(File.expand_path("../fixtures/jsx/button.jsx", __dir__)) }
    let(:expected_rb) { File.read(File.expand_path("../fixtures/expected/button_component.rb", __dir__)) }
    let(:expected_erb) { File.read(File.expand_path("../fixtures/expected/button_component.html.erb", __dir__)) }

    it "emits button_component.rb matching the golden fixture" do
      files = files_for(source)

      expect(files["button_component.rb"]).to eq(expected_rb)
    end

    it "emits button_component.html.erb matching the golden fixture" do
      files = files_for(source)

      expect(files["button_component.html.erb"]).to eq(expected_erb)
    end
  end

  describe "Disclosure fixture (slots + conditional rendering)" do
    let(:source) { File.read(File.expand_path("../fixtures/jsx/disclosure.jsx", __dir__)) }
    let(:expected_rb) { File.read(File.expand_path("../fixtures/expected/disclosure_component.rb", __dir__)) }
    let(:expected_erb) { File.read(File.expand_path("../fixtures/expected/disclosure_component.html.erb", __dir__)) }

    it "emits disclosure_component.rb matching the golden fixture" do
      files = files_for(source)

      expect(files["disclosure_component.rb"]).to eq(expected_rb)
    end

    it "emits disclosure_component.html.erb matching the golden fixture" do
      files = files_for(source)

      expect(files["disclosure_component.html.erb"]).to eq(expected_erb)
    end
  end

  describe "slots and content" do
    it "filters the children prop out of the initializer" do
      files = files_for("function X({ children }) { return <p>{children}</p>; }")

      expect(files["x_component.rb"]).not_to include("children:")
      expect(files["x_component.rb"]).to include("class XComponent < ::ViewComponent::Base\nend")
    end

    it "renders {children} as <%= content %>" do
      files = files_for("function X({ children }) { return <p>{children}</p>; }")

      expect(files["x_component.html.erb"]).to include("<%= content %>")
      expect(files["x_component.html.erb"]).not_to include("@children")
    end
  end

  describe "conditional rendering" do
    it "emits an if/end block for {cond && X}" do
      files = files_for("function X({ open }) { return <div>{open && <p>shown</p>}</div>; }")

      expect(files["x_component.html.erb"]).to include("<% if @open %>")
      expect(files["x_component.html.erb"]).to include("<% end %>")
      expect(files["x_component.html.erb"]).not_to include("<% else %>")
    end

    it "emits an if/else/end block for {cond ? X : Y}" do
      files = files_for("function X({ open }) { return <div>{open ? <a /> : <b />}</div>; }")

      expect(files["x_component.html.erb"]).to include("<% if @open %>")
      expect(files["x_component.html.erb"]).to include("<% else %>")
      expect(files["x_component.html.erb"]).to include("<% end %>")
    end
  end

  describe "Ruby class generation" do
    it "uses ::ViewComponent::Base as the parent class" do
      files = files_for("function Greeting() { return <p>hi</p>; }")

      expect(files["greeting_component.rb"]).to include("< ::ViewComponent::Base")
    end

    it "snake_cases prop names in initialize kwargs and instance vars" do
      files = files_for("function X({ onClick, isOpen }) { return <div />; }")

      expect(files["x_component.rb"]).to include("def initialize(on_click: nil, is_open: nil)")
      expect(files["x_component.rb"]).to include("@on_click = on_click")
      expect(files["x_component.rb"]).to include("@is_open = is_open")
    end

    it "emits translated default values for simple literals" do
      files = files_for('function X({ size = 4, label = "hi" }) { return <div />; }')

      expect(files["x_component.rb"]).to include("size: 4")
      expect(files["x_component.rb"]).to include('label: "hi"')
    end

    it "emits a TODO marker for non-trivial default expressions" do
      files = files_for("function X({ items = computeItems() }) { return <div />; }")

      expect(files["x_component.rb"]).to include("items: nil # TODO: translate")
    end
  end

  describe "ERB template generation" do
    it "emits literal string attributes verbatim" do
      files = files_for('function X() { return <a href="/about" />; }')

      expect(files["x_component.html.erb"]).to include('href="/about"')
    end

    it "translates expression-container attributes to ERB tags using prop instance vars" do
      files = files_for("function X({ url }) { return <a href={url} />; }")

      expect(files["x_component.html.erb"]).to include('href="<%= @url %>"')
    end

    it "inlines simple template-literal class bindings into the class attribute" do
      files = files_for("function X({ variant }) { return <div className={`btn-${variant}`} />; }")

      expect(files["x_component.html.erb"]).to include('class="btn-<%= @variant %>"')
    end

    it "wraps non-template className expressions in a single ERB tag" do
      files = files_for("function X({ extra }) { return <div className={extra} />; }")

      expect(files["x_component.html.erb"]).to include('class="<%= @extra %>"')
    end

    it "renders text children verbatim" do
      files = files_for("function X() { return <p>Hello there</p>; }")

      expect(files["x_component.html.erb"]).to include("<p>\n  Hello there\n</p>")
    end

    it "renders a self-closing element with no children inline" do
      files = files_for("function X() { return <hr />; }")

      expect(files["x_component.html.erb"]).to include("<hr></hr>")
    end

    it "renders nested component invocations as `render`" do
      files = files_for("function X() { return <div><Inner foo={bar} /></div>; }")

      expect(files["x_component.html.erb"]).to include("<%= render InnerComponent.new(foo: bar) %>")
    end

    it "emits a TODO marker for unsupported interpolations" do
      files = files_for("function X() { return <p>{a + b}</p>; }")

      expect(files["x_component.html.erb"]).to include("<%# TODO: translate")
    end
  end

  describe "file naming" do
    it "snake_cases the component name and appends _component" do
      files = files_for("function MyButton() { return <div />; }")

      expect(files.keys).to contain_exactly("my_button_component.rb", "my_button_component.html.erb")
    end
  end
end
