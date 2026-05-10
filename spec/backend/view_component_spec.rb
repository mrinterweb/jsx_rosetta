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

  describe "List fixture (loops + member-expression access)" do
    let(:source) { File.read(File.expand_path("../fixtures/jsx/list.jsx", __dir__)) }
    let(:expected_rb) { File.read(File.expand_path("../fixtures/expected/list_component.rb", __dir__)) }
    let(:expected_erb) { File.read(File.expand_path("../fixtures/expected/list_component.html.erb", __dir__)) }

    it "emits list_component.rb matching the golden fixture" do
      files = files_for(source)

      expect(files["list_component.rb"]).to eq(expected_rb)
    end

    it "emits list_component.html.erb matching the golden fixture" do
      files = files_for(source)

      expect(files["list_component.html.erb"]).to eq(expected_erb)
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

  describe "event bindings" do
    it "renders a single onClick prop as data-action" do
      files = files_for("function X({ onClick }) { return <button onClick={onClick} />; }")

      expect(files["x_component.html.erb"]).to include('data-action="<%= @on_click %>"')
      expect(files["x_component.html.erb"]).not_to include("onClick=")
    end

    it "concatenates multiple event bindings into a single data-action" do
      files = files_for(<<~JSX)
        function X({ onClick, onMouseEnter }) {
          return <button onClick={onClick} onMouseEnter={onMouseEnter} />;
        }
      JSX

      expect(files["x_component.html.erb"]).to include('data-action="<%= @on_click %> <%= @on_mouse_enter %>"')
    end
  end

  describe "loops" do
    it "renders items.map(...) as <% items.each do |item| %>" do
      files = files_for("function X({ items }) { return <ul>{items.map((item) => <li />)}</ul>; }")

      expect(files["x_component.html.erb"]).to include("<% @items.each do |item| %>")
      expect(files["x_component.html.erb"]).to include("<% end %>")
    end

    it "passes both bindings to the each block when an index is present" do
      files = files_for("function X({ items }) { return <ul>{items.map((it, i) => <li />)}</ul>; }")

      expect(files["x_component.html.erb"]).to include("<% @items.each do |it, i| %>")
    end

    it "treats loop-local identifiers as locals (no @-prefix) inside the body" do
      jsx = "function X({ items }) { return <ul>{items.map((item) => <li>{item.name}</li>)}</ul>; }"
      files = files_for(jsx)

      expect(files["x_component.html.erb"]).to include("<%= item.name %>")
      expect(files["x_component.html.erb"]).not_to include("@item.name")
      expect(files["x_component.html.erb"]).not_to include("<%= @item ")
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

    it "renders a void element as self-closing" do
      files = files_for("function X() { return <hr />; }")

      expect(files["x_component.html.erb"]).to include("<hr />")
      expect(files["x_component.html.erb"]).not_to include("</hr>")
    end

    it "renders a void element with attributes as self-closing" do
      files = files_for('function X() { return <img src="/a.png" alt="x" />; }')

      expect(files["x_component.html.erb"]).to include('<img src="/a.png" alt="x" />')
      expect(files["x_component.html.erb"]).not_to include("</img>")
    end

    it "switches to tag.* builder when an Element has a spread attribute" do
      files = files_for("function X({ rest }) { return <button className=\"x\" {...rest}>Click</button>; }")

      erb = files["x_component.html.erb"]
      expect(erb).to include("<%= tag.button(class: \"x\", **@rest) do %>")
      expect(erb).to include("<% end %>")
      expect(erb).not_to include("<button class=")
    end

    it "renders a void element with spread via the tag builder" do
      files = files_for("function X({ rest }) { return <input type=\"text\" {...rest} />; }")

      erb = files["x_component.html.erb"]
      expect(erb).to include("<%= tag.input(type: \"text\", **@rest) %>")
      expect(erb).not_to include("<input")
    end

    it "renders nested component invocations as `render`" do
      files = files_for("function X() { return <div><Inner foo={bar} /></div>; }")

      expect(files["x_component.html.erb"]).to include("<%= render InnerComponent.new(foo: bar) %>")
    end

    it "passes a spread argument as **rest in a component invocation" do
      files = files_for("function X({ rest }) { return <Inner title=\"x\" {...rest} />; }")

      erb = files["x_component.html.erb"]
      expect(erb).to include('<%= render InnerComponent.new(title: "x", **@rest) %>')
    end

    it "spreads a rest-destructured prop as **@rest_name (not **rest_name)" do
      files = files_for("function X({ a, ...props }) { return <Inner title={a} {...props} />; }")

      erb = files["x_component.html.erb"]
      expect(erb).to include("**@props")
      expect(erb).not_to match(/\*\*props(?!\w)/) # bare `**props` would mean an undefined local
    end

    it "renders cn() className as inline ERB on an Element" do
      files = files_for('function X({ extra }) { return <div className={cn("base", extra, { "active": extra })} />; }')

      erb = files["x_component.html.erb"]
      expect(erb).to include('class="base <%= @extra %> <%= @extra ? "active" : \'\' %>"')
    end

    it "renders cn() className as a Ruby string on a ComponentInvocation" do
      files = files_for('function X({ flag }) { return <Inner className={cn("base", { "on": flag })} />; }')

      erb = files["x_component.html.erb"]
      expect(erb).to include(%(class: "base \#{@flag ? "on" : ""}"))
    end

    it "uses a quoted-key hash entry for hyphenated component-invocation kwargs" do
      files = files_for("function X({ label }) { return <Inner aria-label={label} />; }")

      erb = files["x_component.html.erb"]
      expect(erb).to include('<%= render InnerComponent.new("aria-label" => @label) %>')
    end

    it "emits a TODO marker for unsupported interpolations" do
      files = files_for("function X() { return <p>{a + b}</p>; }")

      expect(files["x_component.html.erb"]).to include("<%# TODO: translate")
    end

    it "generates an initializer with **rest when the component destructures a rest binding" do
      files = files_for("function X({ a, ...rest }) { return <div />; }")

      ruby = files["x_component.rb"]
      expect(ruby).to include("def initialize(a: nil, **rest)")
      expect(ruby).to include("@a = a")
      expect(ruby).to include("@rest = rest")
    end

    it "generates an initializer with only **rest when no other props are present" do
      files = files_for("function X({ ...rest }) { return <div />; }")

      ruby = files["x_component.rb"]
      expect(ruby).to include("def initialize(**rest)")
      expect(ruby).to include("@rest = rest")
    end

    it "renders inline styles as a style=\"...\" attribute on an Element" do
      files = files_for("function X({ size }) { return <div style={{ fontSize: size, color: \"red\" }} />; }")

      erb = files["x_component.html.erb"]
      expect(erb).to include('style="font-size: <%= @size %>; color: red;"')
    end

    it "renders inline styles as a Ruby string on a ComponentInvocation" do
      files = files_for("function X({ size }) { return <Inner style={{ fontSize: size }} />; }")

      erb = files["x_component.html.erb"]
      expect(erb).to include(%(style: "font-size: \#{@size};"))
    end

    it "prepends a TODO comment listing non-JSX local bindings" do
      files = files_for(<<~JSX)
        function X({ raw }) {
          const date = parseISO(raw);
          return <time>{date}</time>;
        }
      JSX

      erb = files["x_component.html.erb"]
      expect(erb).to include("<%# TODO: translate JS to Ruby")
      expect(erb).to include("const date = parseISO(raw);")
    end

    it "renders a JSX block comment as an ERB comment" do
      files = files_for("function X() { return <p>{/* note: be careful */}body</p>; }")

      expect(files["x_component.html.erb"]).to include("<%# note: be careful %>")
    end

    it "flags an interpolation whose identifier is neither a prop nor a local" do
      files = files_for(<<~JSX)
        import { CMS_NAME } from "@/lib/constants";
        function X() { return <p>{CMS_NAME}</p>; }
      JSX

      erb = files["x_component.html.erb"]
      expect(erb).to include("TODO: unresolved identifier")
      expect(erb).to include('"CMS_NAME"')
      expect(erb).to include("<%= cms_name %>")
    end
  end

  describe "file naming" do
    it "snake_cases the component name and appends _component" do
      files = files_for("function MyButton() { return <div />; }")

      expect(files.keys).to contain_exactly("my_button_component.rb", "my_button_component.html.erb")
    end
  end
end
