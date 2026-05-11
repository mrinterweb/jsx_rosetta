# frozen_string_literal: true

RSpec.describe JsxRosetta::Backend::ViewComponent do
  # Default to flat layout in these tests — the sidecar layout has its own
  # describe block below. Most existing assertions index by flat paths
  # (e.g. "x_component.html.erb"), and rewriting them all is churn that
  # adds no signal beyond what the sidecar describe block covers.
  subject(:backend) { described_class.new(layout: :flat) }

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
    it "promotes a single prop-bound onClick into a Stimulus action descriptor" do
      files = files_for("function X({ onClick }) { return <button onClick={onClick} />; }")

      expect(files["x_component.html.erb"]).to include('data-controller="x"')
      expect(files["x_component.html.erb"]).to include('data-action="click->x#onClick"')
      expect(files["x_component.html.erb"]).not_to include("onClick=")
    end

    it "concatenates multiple prop-bound event handlers into one data-action descriptor list" do
      files = files_for(<<~JSX)
        function X({ onClick, onMouseEnter }) {
          return <button onClick={onClick} onMouseEnter={onMouseEnter} />;
        }
      JSX

      expect(files["x_component.html.erb"]).to include('data-action="click->x#onClick mouseenter->x#onMouseEnter"')
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

    # `error && <X />` where `error` is destructured from a hook would
    # collapse to `<% if nil %>` (the translator returns `"nil"` so the
    # file loads). That's silently never-rendering. Falling back to the
    # verbatim expression makes the JS source visible to the reviewer.
    it "falls back to the verbatim expression when the test resolves to a known local" do
      source = <<~JSX
        function X() {
          const { error } = useQuery();
          return <div>{error && <p>err</p>}</div>;
        }
      JSX
      files = files_for(source)

      expect(files["x_component.html.erb"]).not_to include("<% if nil %>")
      expect(files["x_component.html.erb"]).to include("<% if error %>")
    end
  end

  describe "nested render-function locals" do
    # ERB ViewComponent doesn't have a clean way to render Ruby-method
    # bodies into the template inline, so the template emits a call
    # invocation and the class gets a method skeleton with a TODO. The
    # reviewer fills in the body by hand.
    it "emits the method invocation at the use site and a skeleton on the class" do
      source = <<~JSX
        function X() {
          const renderHeader = () => <h1>Header</h1>;
          return <main>{renderHeader()}</main>;
        }
      JSX
      files = files_for(source)

      expect(files["x_component.html.erb"]).to include("<%= render_header %>")
      expect(files["x_component.rb"]).to include("def render_header")
      expect(files["x_component.rb"]).to include("# TODO: translate the JSX body for render_header")
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
      expect(files["x_component.rb"]).to include("label: 'hi'")
    end

    it "emits `nil` (no inline TODO) for non-trivial default expressions" do
      # An inline `# TODO: ...` comment inside the initialize(...) parameter
      # list swallows the closing `)` and breaks Ruby syntax, so we just
      # emit `nil` and leave the reviewer to consult the JSX source for
      # what the original default was.
      files = files_for("function X({ items = computeItems() }) { return <div />; }")

      expect(files["x_component.rb"]).to include("items: nil")
      expect(files["x_component.rb"]).not_to include("# TODO: translate")
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
      expect(erb).to include("<%= tag.button(class: 'x', **(@rest || {})) do %>")
      expect(erb).to include("<% end %>")
      expect(erb).not_to include("<button class=")
    end

    it "renders a void element with spread via the tag builder" do
      files = files_for("function X({ rest }) { return <input type=\"text\" {...rest} />; }")

      erb = files["x_component.html.erb"]
      expect(erb).to include("<%= tag.input(type: \"text\", **(@rest || {})) %>")
      expect(erb).not_to include("<input")
    end

    it "renders nested component invocations as `render`" do
      files = files_for("function X() { return <div><Inner foo={bar} /></div>; }")

      expect(files["x_component.html.erb"]).to include("<%= render InnerComponent.new(foo: bar) %>")
    end

    it "translates compound component tags `<Foo.Bar>` to `Foo::BarComponent`" do
      files = files_for("function X() { return <Tabs.List><Tabs.Trigger value=\"a\" /></Tabs.List>; }")

      erb = files["x_component.html.erb"]
      expect(erb).to include("Tabs::ListComponent")
      expect(erb).to include('Tabs::TriggerComponent.new(value: "a")')
      expect(erb).not_to include("Tabs.ListComponent")
      expect(erb).not_to include("Tabs.TriggerComponent")
    end

    it "emits link_to instead of LinkComponent.new for the default Link mapping" do
      files = files_for('function X() { return <Link href="/posts">Read</Link>; }')

      erb = files["x_component.html.erb"]
      expect(erb).to include('<%= link_to("/posts") do %>')
      expect(erb).not_to include("LinkComponent")
    end

    it "emits image_tag (no block) for the default Image mapping" do
      files = files_for('function X() { return <Image src="/a.png" alt="x" />; }')

      erb = files["x_component.html.erb"]
      expect(erb).to include('<%= image_tag("/a.png", alt: "x") %>')
      expect(erb).not_to include("ImageComponent")
    end

    it "passes spread and hyphenated kwargs through to a mapped helper" do
      files = files_for('function X({ rest, label }) { return <Link href="/" aria-label={label} {...rest}>Hi</Link>; }')

      erb = files["x_component.html.erb"]
      expect(erb).to include('<%= link_to("/", "aria-label" => @label, **(@rest || {})) do %>')
    end

    it "respects an explicit helpers map override" do
      files = JsxRosetta.translate(
        'function X() { return <Btn href="/" />; }',
        helpers: { "Btn" => { method: :button_to, positional: :href } },
        layout: :flat
      ).to_h { |f| [f.path, f.contents] }

      expect(files["x_component.html.erb"]).to include('<%= button_to("/") %>')
    end

    it "disables helper mapping entirely when helpers: false is passed" do
      files = JsxRosetta.translate(
        'function X() { return <Link href="/">Hi</Link>; }',
        helpers: false,
        layout: :flat
      ).to_h { |f| [f.path, f.contents] }

      expect(files["x_component.html.erb"]).to include("LinkComponent.new")
      expect(files["x_component.html.erb"]).not_to include("link_to")
    end

    it "snake_cases camelCase identifiers within a member chain" do
      files = files_for("function X({ post }) { return <p>{post.coverImage}</p>; }")

      expect(files["x_component.html.erb"]).to include("@post.cover_image")
      expect(files["x_component.html.erb"]).not_to include("coverImage")
    end

    it "inlines a template-literal href and translates member chains within it" do
      files = files_for("function X({ post }) { return <a href={`/posts/${post.id}`}>x</a>; }")

      erb = files["x_component.html.erb"]
      expect(erb).to include('href="/posts/<%= @post.id %>"')
      expect(erb).not_to include("TODO")
      expect(erb).not_to include('href="<%= ')
    end

    it "inlines plain identifier interpolation in attribute values" do
      files = files_for("function X({ slug }) { return <a href={`/posts/${slug}`}>x</a>; }")

      erb = files["x_component.html.erb"]
      expect(erb).to include('href="/posts/<%= @slug %>"')
    end

    it "translates `!preview` to `!@preview` (unary negation on a prop)" do
      files = files_for("function X({ preview }) { return <p>{!preview}</p>; }")

      erb = files["x_component.html.erb"]
      expect(erb).to include("<%= !@preview %>")
    end

    it "translates `!member.chain` correctly" do
      files = files_for("function X({ post }) { return <p>{!post.published}</p>; }")

      erb = files["x_component.html.erb"]
      expect(erb).to include("<%= !@post.published %>")
    end

    it "passes a spread argument as **rest in a component invocation" do
      files = files_for("function X({ rest }) { return <Inner title=\"x\" {...rest} />; }")

      erb = files["x_component.html.erb"]
      expect(erb).to include('<%= render InnerComponent.new(title: "x", **(@rest || {})) %>')
    end

    it "spreads a rest-destructured prop as **@rest_name (not **rest_name)" do
      files = files_for("function X({ a, ...props }) { return <Inner title={a} {...props} />; }")

      erb = files["x_component.html.erb"]
      expect(erb).to include("**(@props || {})")
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

    it "emits a Stimulus controller file when stimulus_methods is non-empty" do
      files = files_for("function CopyButton() { return <button onClick={() => copy()}>Copy</button>; }")

      expect(files).to have_key("copy_button_controller.js")
      controller = files["copy_button_controller.js"]
      expect(controller).to include('import { Controller } from "@hotwired/stimulus";')
      expect(controller).to include("export default class extends Controller")
      expect(controller).to include("clickHandler(event)")
      expect(controller).to include("//   copy()")
    end

    it "wires data-controller and data-action on the root element when Stimulus methods exist" do
      files = files_for("function CopyButton() { return <button onClick={() => copy()}>Copy</button>; }")

      erb = files["copy_button_component.html.erb"]
      expect(erb).to include('data-controller="copy-button"')
      expect(erb).to include('data-action="click->copy-button#clickHandler"')
    end

    it "does not emit a controller file when there are no Stimulus methods" do
      files = files_for("function X() { return <p />; }")

      expect(files.keys).not_to include(a_string_matching(/_controller\.js\z/))
    end

    it "prepends a distinct TODO comment block when React hooks are detected" do
      files = files_for(<<~JSX)
        function X() {
          const [open, setOpen] = useState(false);
          useEffect(() => {});
          return <div />;
        }
      JSX

      erb = files["x_component.html.erb"]
      expect(erb).to include("React hooks detected")
      expect(erb).to include("useState(false)")
      expect(erb).to include("useEffect")
      expect(erb).to include("Hotwire/Stimulus")
    end

    it "emits a separate Apollo TODO block with operation name when useQuery is present" do
      files = files_for(<<~JSX)
        function X() {
          const { data } = useQuery(GET_USERS);
          return <p>{data}</p>;
        }
      JSX

      erb = files["x_component.html.erb"]
      expect(erb).to include("Apollo data-fetching hooks detected")
      expect(erb).to include("operation: GET_USERS")
      expect(erb).to include("useQuery(GET_USERS)")
      expect(erb).not_to include("React hooks detected")
    end

    it "emits a separate Next.js TODO block with Rails analogs for navigation hooks" do
      files = files_for(<<~JSX)
        function X() {
          const path = usePathname();
          return <p>{path}</p>;
        }
      JSX

      erb = files["x_component.html.erb"]
      expect(erb).to include("Next.js navigation hooks detected")
      expect(erb).to include("usePathname -> request.path")
      expect(erb).to include("usePathname()")
      expect(erb).not_to include("React hooks detected")
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

  describe "sidecar layout (default)" do
    let(:sidecar_backend) { described_class.new }

    def sidecar_files_for(jsx_source)
      component = JsxRosetta.lower(jsx_source)
      sidecar_backend.emit(component).to_h { |file| [file.path, file.contents] }
    end

    it "puts the .rb at the top level and the .html.erb in a sidecar subdirectory" do
      files = sidecar_files_for("function X() { return <p>Hi</p>; }")

      expect(files.keys).to contain_exactly(
        "x_component.rb",
        "x_component/x_component.html.erb"
      )
    end

    it "puts the Stimulus controller in the sidecar subdirectory alongside the template" do
      files = sidecar_files_for("function CopyButton() { return <button onClick={() => copy()}>x</button>; }")

      expect(files.keys).to contain_exactly(
        "copy_button_component.rb",
        "copy_button_component/copy_button_component.html.erb",
        "copy_button_component/copy_button_controller.js"
      )
    end

    it "raises ArgumentError on an unknown layout" do
      expect { described_class.new(layout: :nested) }.to raise_error(ArgumentError, /unknown layout/)
    end
  end
end
