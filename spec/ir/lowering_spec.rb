# frozen_string_literal: true

RSpec.describe JsxRosetta::IR::Lowering do
  def lower(source)
    described_class.lower(JsxRosetta.parse(source), source: source)
  end

  describe "key prop" do
    it "drops `key` from a ComponentInvocation's props" do
      ir = lower("function X() { return <Inner key={id} title={t} />; }")

      expect(ir.body).to be_a(JsxRosetta::IR::ComponentInvocation)
      expect(ir.body.props.map { |p| p.respond_to?(:name) ? p.name : nil }).not_to include("key")
      expect(ir.body.props.map { |p| p.respond_to?(:name) ? p.name : nil }).to include("title")
    end

    it "drops `key` on an HTML Element too (React-only hint, not a DOM attribute)" do
      ir = lower("function X() { return <li key={id} />; }")

      expect(ir.body).to be_a(JsxRosetta::IR::Element)
      expect(ir.body.attributes.map(&:name)).not_to include("key")
    end
  end

  describe "html elements vs component invocations" do
    it "lowers a lowercase tag to IR::Element" do
      ir = lower("function X() { return <div />; }")

      expect(ir.body).to eq(JsxRosetta::IR::Element.new(tag: "div", attributes: [], children: []))
    end

    it "lowers a capitalized tag to IR::ComponentInvocation" do
      ir = lower("function X() { return <Button />; }")

      expect(ir.body).to eq(JsxRosetta::IR::ComponentInvocation.new(name: "Button", props: [], children: []))
    end

    it "lowers a member-expression tag to IR::ComponentInvocation" do
      ir = lower("function X() { return <Foo.Bar />; }")

      expect(ir.body).to be_a(JsxRosetta::IR::ComponentInvocation)
      expect(ir.body.name).to eq("Foo.Bar")
    end
  end

  describe "attributes" do
    it "lowers a literal string attribute to a plain Attribute" do
      ir = lower('function X() { return <a href="/about" />; }')

      attr = ir.body.attributes.first
      expect(attr).to eq(JsxRosetta::IR::Attribute.new(name: "href", value: "/about"))
    end

    it "lowers an expression-container attribute to an Interpolation value" do
      ir = lower("function X() { return <a href={url} />; }")

      attr = ir.body.attributes.first
      expect(attr).to eq(
        JsxRosetta::IR::Attribute.new(name: "href", value: JsxRosetta::IR::Interpolation.new(expression: "url"))
      )
    end

    it "lowers a value-less attribute to value: true" do
      ir = lower("function X() { return <input disabled />; }")

      attr = ir.body.attributes.first
      expect(attr).to eq(JsxRosetta::IR::Attribute.new(name: "disabled", value: true))
    end

    it "lowers className to IR::StyleBinding (literal string)" do
      ir = lower('function X() { return <a className="btn primary" />; }')

      style = ir.body.attributes.first
      expect(style).to be_a(JsxRosetta::IR::StyleBinding)
      expect(style.expression).to eq('"btn primary"')
    end

    it "lowers className with a non-helper expression to IR::StyleBinding" do
      ir = lower('function X() { return <a className={ternary ? "a" : "b"} />; }')

      style = ir.body.attributes.first
      expect(style).to be_a(JsxRosetta::IR::StyleBinding)
      expect(style.expression).to eq('ternary ? "a" : "b"')
    end
  end

  describe "children" do
    it "preserves non-whitespace text" do
      ir = lower("function X() { return <p>Hello</p>; }")

      expect(ir.body.children).to eq([JsxRosetta::IR::Text.new(value: "Hello")])
    end

    it "drops pure-whitespace text between siblings" do
      ir = lower("function X() { return <ul>\n  <li />\n  <li />\n</ul>; }")

      expect(ir.body.children.size).to eq(2)
      expect(ir.body.children).to all(be_a(JsxRosetta::IR::Element))
    end

    it "lowers expression-container children to Interpolation" do
      ir = lower("function X() { return <p>{name}</p>; }")

      expect(ir.body.children).to eq([JsxRosetta::IR::Interpolation.new(expression: "name")])
    end

    it "lowers a string-literal expression container to Text" do
      ir = lower('function X() { return <p>a{" "}b</p>; }')

      expect(ir.body.children).to include(JsxRosetta::IR::Text.new(value: " "))
      expect(ir.body.children).not_to include(a_kind_of(JsxRosetta::IR::Interpolation))
    end

    it "lowers a numeric-literal expression container to Text" do
      ir = lower("function X() { return <p>{42}</p>; }")

      expect(ir.body.children).to eq([JsxRosetta::IR::Text.new(value: "42")])
    end

    it "drops boolean-literal and null-literal expression containers" do
      ir = lower("function X() { return <p>{true}{null}{false}</p>; }")

      expect(ir.body.children).to eq([])
    end

    it "lowers a JSX block comment to IR::Comment" do
      ir = lower("function X() { return <p>{/* hello */}</p>; }")

      expect(ir.body.children).to eq([JsxRosetta::IR::Comment.new(text: "hello")])
    end

    it "joins multiple inner comments inside one expression container" do
      ir = lower("function X() { return <p>{/* a */ /* b */}</p>; }")

      expect(ir.body.children.first).to be_a(JsxRosetta::IR::Comment)
      expect(ir.body.children.first.text).to include("a")
      expect(ir.body.children.first.text).to include("b")
    end

    it "lowers a {children} reference to IR::Slot when children is a prop" do
      ir = lower("function X({ children }) { return <p>{children}</p>; }")

      expect(ir.body.children).to eq([JsxRosetta::IR::Slot.new(name: "children")])
    end

    it "leaves {children} as Interpolation when children is not a prop" do
      ir = lower("function X() { return <p>{children}</p>; }")

      expect(ir.body.children).to eq([JsxRosetta::IR::Interpolation.new(expression: "children")])
    end

    it "normalizes JSX whitespace (Babel rules) for inline text with surrounding indentation" do
      ir = lower(<<~JSX)
        function X() {
          return (
            <h3>
              Statically Generated with Next.js.
            </h3>
          );
        }
      JSX

      expect(ir.body.children).to eq([JsxRosetta::IR::Text.new(value: "Statically Generated with Next.js.")])
    end

    it "joins multi-line inline text with single spaces" do
      ir = lower(<<~JSX)
        function X() {
          return (
            <p>
              line one
              line two
            </p>
          );
        }
      JSX

      expect(ir.body.children).to eq([JsxRosetta::IR::Text.new(value: "line one line two")])
    end
  end

  describe "local JSX bindings" do
    it "inlines a `const x = <jsx />` binding when referenced as `{x}`" do
      ir = lower(<<~JSX)
        function X({ src }) {
          const image = <img src={src} />;
          return <div>{image}</div>;
        }
      JSX

      child = ir.body.children.first
      expect(child).to be_a(JsxRosetta::IR::Element)
      expect(child.tag).to eq("img")
    end

    it "inlines a JSX binding into a ternary alternate" do
      ir = lower(<<~JSX)
        function X({ on }) {
          const fallback = <span />;
          return <div>{on ? <strong /> : fallback}</div>;
        }
      JSX

      conditional = ir.body.children.first
      expect(conditional).to be_a(JsxRosetta::IR::Conditional)
      expect(conditional.alternate).to be_a(JsxRosetta::IR::Element)
      expect(conditional.alternate.tag).to eq("span")
    end

    it "leaves a non-JSX local binding's identifier as a bare Interpolation" do
      ir = lower(<<~JSX)
        function X({ raw }) {
          const computed = parse(raw);
          return <p>{computed}</p>;
        }
      JSX

      expect(ir.body.children).to eq([JsxRosetta::IR::Interpolation.new(expression: "computed")])
    end

    it "captures non-JSX local bindings on Component#local_bindings" do
      ir = lower(<<~JSX)
        function X({ raw }) {
          const date = parseISO(raw);
          const total = items.reduce((s, i) => s + i.price, 0);
          return <time>{date}</time>;
        }
      JSX

      expect(ir.local_bindings.map(&:name)).to eq(%w[date total])
      expect(ir.local_bindings.first.source).to eq("const date = parseISO(raw);")
      expect(ir.local_bindings.last.source).to eq("const total = items.reduce((s, i) => s + i.price, 0);")
    end

    it "leaves local_bindings empty when there are no non-JSX bindings" do
      ir = lower("function X() { return <p />; }")

      expect(ir.local_bindings).to eq([])
    end
  end

  describe "event bindings" do
    it "promotes on*={prop} to IR::StimulusBinding (handler name derived from the identifier)" do
      ir = lower("function X({ onClick }) { return <button onClick={onClick} />; }")

      event = ir.body.attributes.first
      expect(event).to be_a(JsxRosetta::IR::StimulusBinding)
      expect(event.event).to eq("click")
      expect(event.method_name).to eq("onClick")
    end

    it "translates onMouseEnter to the native event name and promotes the prop ref" do
      ir = lower("function X({ onMouseEnter }) { return <div onMouseEnter={onMouseEnter} />; }")

      attr = ir.body.attributes.first
      expect(attr).to be_a(JsxRosetta::IR::StimulusBinding)
      expect(attr.event).to eq("mouseenter")
    end

    it "leaves on*=\"literal\" attributes alone (no expression container)" do
      ir = lower('function X() { return <button onClick="alert(1)" />; }')

      expect(ir.body.attributes.first).to be_a(JsxRosetta::IR::Attribute)
    end
  end

  describe "React hook detection" do
    it "captures `const [x, setX] = useState(...)` calls into react_hooks" do
      ir = lower(<<~JSX)
        function X() {
          const [open, setOpen] = useState(false);
          return <div />;
        }
      JSX

      expect(ir.react_hooks.size).to eq(1)
      expect(ir.react_hooks.first.hook).to eq("useState")
      expect(ir.react_hooks.first.source).to include("useState(false)")
    end

    it "captures bare `useEffect(() => {})` expression statements" do
      ir = lower(<<~JSX)
        function X() {
          useEffect(() => { console.log("mounted"); });
          return <div />;
        }
      JSX

      expect(ir.react_hooks.map(&:hook)).to eq(["useEffect"])
    end

    it "captures multiple hooks in source order" do
      ir = lower(<<~JSX)
        function X() {
          const [a, setA] = useState(0);
          const ref = useRef(null);
          const ctx = useContext(MyContext);
          return <div />;
        }
      JSX

      expect(ir.react_hooks.map(&:hook)).to eq(%w[useState useRef useContext])
    end

    it "does not record hook calls in local_bindings (so the human gets one TODO, not two)" do
      ir = lower(<<~JSX)
        function X() {
          const [open, setOpen] = useState(false);
          return <div />;
        }
      JSX

      expect(ir.local_bindings).to eq([])
    end

    it "exposes hook destructure names in local_binding_names so the translator can recognize them" do
      # Gap A: `const [open, setOpen] = useState(false); ... {open}` would
      # otherwise emit a bare `open` reference that NameErrors at render time.
      # Translator awareness is the cure; the TODO duplication is avoided by
      # keeping these names out of `local_bindings` (the reviewer already
      # sees the hook source in the hooks TODO block).
      ir = lower(<<~JSX)
        function X() {
          const [open, setOpen] = useState(false);
          return <div />;
        }
      JSX

      expect(ir.local_binding_names).to contain_exactly("open", "setOpen")
    end

    it "extracts a JSX-returning local arrow into render_methods with a LocalRenderCall at the use site" do
      # `const renderHeader = () => <h1/>; ... {renderHeader()}` used to
      # drop to `Interpolation("renderHeader()")` at the use site. Now the
      # arrow is captured as a RenderMethod and the call as a
      # LocalRenderCall pointing at it.
      ir = lower(<<~JSX)
        function X() {
          const renderHeader = (count) => <h1>{count}</h1>;
          return <main>{renderHeader(headerCount)}</main>;
        }
      JSX

      expect(ir.render_methods.size).to eq(1)
      rm = ir.render_methods.first
      expect(rm.name).to eq("render_header")
      expect(rm.params).to eq(["count"])
      expect(rm.body).to be_a(JsxRosetta::IR::Element)

      call = ir.body.children.first
      expect(call).to be_a(JsxRosetta::IR::LocalRenderCall)
      expect(call.method_name).to eq("render_header")
      expect(call.args.map(&:expression)).to eq(["headerCount"])
    end

    it "exposes Identifier-bound hook results (useCallback / useRef / useMemo) as local_binding_names" do
      # `const handleChange = useCallback(...)` is not a destructure, so
      # earlier versions of classify_local_binding dropped it on the floor.
      # Without the binding name on record, the translator emits
      # `on_change: handle_change` at the use site — a NameError. Recording
      # it makes the translator emit `nil` instead.
      ir = lower(<<~JSX)
        function X() {
          const handleChange = useCallback(() => 1, []);
          const ref = useRef(null);
          const memoed = useMemo(() => 2, []);
          return <div />;
        }
      JSX

      expect(ir.local_binding_names).to contain_exactly("handleChange", "ref", "memoed")
      expect(ir.local_bindings).to be_empty
      expect(ir.react_hooks.map(&:hook)).to eq(%w[useCallback useRef useMemo])
    end

    it "tags React hook calls with library: :react and no operation" do
      ir = lower(<<~JSX)
        function X() {
          const [a, setA] = useState(0);
          return <div />;
        }
      JSX

      call = ir.react_hooks.first
      expect(call.library).to eq(:react)
      expect(call.operation).to be_nil
    end
  end

  describe "Apollo hook detection" do
    it "captures useQuery destructures with library: :apollo and the operation name" do
      ir = lower(<<~JSX)
        function X() {
          const { data, loading, error } = useQuery(GET_USERS_QUERY, { variables: { id } });
          return <div />;
        }
      JSX

      expect(ir.react_hooks.size).to eq(1)
      call = ir.react_hooks.first
      expect(call.hook).to eq("useQuery")
      expect(call.library).to eq(:apollo)
      expect(call.operation).to eq("GET_USERS_QUERY")
      expect(call.source).to include("useQuery(GET_USERS_QUERY")
    end

    it "captures useMutation as a tuple destructure with operation name" do
      ir = lower(<<~JSX)
        function X() {
          const [createUser, { loading }] = useMutation(CREATE_USER_MUTATION);
          return <div />;
        }
      JSX

      call = ir.react_hooks.first
      expect(call.hook).to eq("useMutation")
      expect(call.library).to eq(:apollo)
      expect(call.operation).to eq("CREATE_USER_MUTATION")
    end

    it "exposes Apollo destructure names in local_binding_names so use sites translate cleanly" do
      ir = lower(<<~JSX)
        function X() {
          const { data, loading } = useQuery(GET_USERS_QUERY);
          return <p>{loading}</p>;
        }
      JSX

      expect(ir.local_binding_names).to include("data", "loading")
      expect(ir.local_bindings).to be_empty
    end

    it "leaves operation as nil when the GraphQL document is an inline call (e.g. gql`...`)" do
      ir = lower(<<~JSX)
        function X() {
          const { data } = useQuery(gql(`{ users { id } }`));
          return <div />;
        }
      JSX

      call = ir.react_hooks.first
      expect(call.library).to eq(:apollo)
      expect(call.operation).to be_nil
    end

    it "captures bare useLazyQuery / useSubscription calls too" do
      ir = lower(<<~JSX)
        function X() {
          const [load] = useLazyQuery(LIST_POSTS);
          useSubscription(POST_ADDED);
          return <div />;
        }
      JSX

      expect(ir.react_hooks.map(&:hook)).to eq(%w[useLazyQuery useSubscription])
      expect(ir.react_hooks.map(&:library)).to eq(%i[apollo apollo])
      expect(ir.react_hooks.map(&:operation)).to eq(%w[LIST_POSTS POST_ADDED])
    end
  end

  describe "Next.js navigation hook detection" do
    it "captures useRouter / usePathname / useSearchParams with library: :next_js" do
      ir = lower(<<~JSX)
        function X() {
          const router = useRouter();
          const path = usePathname();
          const search = useSearchParams();
          return <div />;
        }
      JSX

      expect(ir.react_hooks.map(&:hook)).to eq(%w[useRouter usePathname useSearchParams])
      expect(ir.react_hooks.map(&:library).uniq).to eq([:next_js])
      expect(ir.react_hooks.map(&:operation)).to eq([nil, nil, nil])
    end

    it "exposes Next.js identifier-bound names in local_binding_names so use sites resolve" do
      ir = lower(<<~JSX)
        function X() {
          const router = useRouter();
          return <p>{router}</p>;
        }
      JSX

      expect(ir.local_binding_names).to include("router")
      expect(ir.local_bindings).to be_empty
    end

    it "captures useParams destructures" do
      ir = lower(<<~JSX)
        function X() {
          const { id } = useParams();
          return <p>{id}</p>;
        }
      JSX

      call = ir.react_hooks.first
      expect(call.hook).to eq("useParams")
      expect(call.library).to eq(:next_js)
      expect(ir.local_binding_names).to include("id")
    end
  end

  describe "Gap A: destructure pattern capture" do
    it "records ArrayPattern destructured names as local bindings" do
      ir = lower(<<~JSX)
        function X() {
          const [first, second] = someTuple;
          return <p>{first}</p>;
        }
      JSX

      expect(ir.local_binding_names).to include("first", "second")
      expect(ir.local_bindings.map(&:name)).to include("first", "second")
    end

    it "records ObjectPattern destructured names as local bindings" do
      ir = lower(<<~JSX)
        function X() {
          const { foo, bar } = thing;
          return <p>{foo}{bar}</p>;
        }
      JSX

      expect(ir.local_binding_names).to include("foo", "bar")
      expect(ir.local_bindings.map(&:name)).to include("foo", "bar")
    end

    it "records aliased ObjectPattern names against the alias, not the source key" do
      ir = lower(<<~JSX)
        function X() {
          const { foo: aliased } = thing;
          return <p>{aliased}</p>;
        }
      JSX

      expect(ir.local_binding_names).to include("aliased")
      expect(ir.local_binding_names).not_to include("foo")
    end

    it "follows AssignmentPattern defaults to the bound name" do
      ir = lower(<<~JSX)
        function X() {
          const [first = 0, second = 1] = tuple;
          return <p>{first}</p>;
        }
      JSX

      expect(ir.local_binding_names).to include("first", "second")
    end

    it "captures RestElement in destructure patterns" do
      ir = lower(<<~JSX)
        function X() {
          const { a, ...rest } = thing;
          return <p>{a}</p>;
        }
      JSX

      expect(ir.local_binding_names).to include("a", "rest")
    end
  end

  describe "Gap E: module-level constants" do
    it "captures `const FOO = 400` outside the component into module_bindings" do
      ir = described_class.lower(JsxRosetta.parse(<<~JSX), source: <<~JSX)
        const FOO = 400;
        function X() { return <p>{FOO}</p>; }
      JSX
        const FOO = 400;
        function X() { return <p>{FOO}</p>; }
      JSX

      expect(ir.module_bindings.map(&:name)).to include("FOO")
    end

    it "doesn't capture the component itself as a module binding" do
      ir = described_class.lower(JsxRosetta.parse(<<~JSX), source: <<~JSX)
        const X = () => <p />;
      JSX
        const X = () => <p />;
      JSX

      expect(ir.module_bindings).to eq([])
    end

    it "captures a top-level `function helper(){}` as a module binding" do
      # Without capture, `function onError(){}` at module level silently
      # disappears, and any reference inside the JSX (e.g. `onClick={onError}`)
      # snake-cases to a bare `on_error` ref that NameErrors at render time.
      ir = lower(<<~JSX)
        function onError(e) { console.error(e); }
        function X() { return <button onClick={onError}>click</button>; }
      JSX

      expect(ir.module_bindings.map(&:name)).to include("onError")
    end

    it "doesn't capture the component itself when declared with FunctionDeclaration" do
      ir = lower("function X() { return <p />; }")

      expect(ir.module_bindings).to eq([])
    end

    it "captures multiple module bindings preserving source order" do
      ir = described_class.lower(JsxRosetta.parse(<<~JSX), source: <<~JSX)
        const FOO = 400;
        const BAR = "x";
        function X() { return <p />; }
      JSX
        const FOO = 400;
        const BAR = "x";
        function X() { return <p />; }
      JSX

      expect(ir.module_bindings.map(&:name)).to eq(%w[FOO BAR])
    end
  end

  describe "HOC unwrapping" do
    it "unwraps `const X = memo(function X(...) {...})` to find the component" do
      ir = lower(<<~JSX)
        const NoteTag = memo(function NoteTag({ label }) { return <span>{label}</span>; });
      JSX

      expect(ir.name).to eq("NoteTag")
      expect(ir.hoc_wrappers).to eq(["memo"])
      expect(ir.props.map(&:name)).to eq(["label"])
    end

    it "unwraps the React.memo namespace form" do
      ir = lower(<<~JSX)
        const NoteTag = React.memo(function NoteTag({ label }) { return <span>{label}</span>; });
      JSX

      expect(ir.hoc_wrappers).to eq(["memo"])
    end

    it "unwraps an arrow-form memo() argument" do
      ir = lower(<<~JSX)
        const NoteTag = memo(({ label }) => <span>{label}</span>);
      JSX

      expect(ir.name).to eq("NoteTag")
      expect(ir.hoc_wrappers).to eq(["memo"])
    end

    it "unwraps forwardRef and drops the trailing ref param" do
      ir = lower(<<~JSX)
        const Button = forwardRef(function Button({ children }, ref) { return <button>{children}</button>; });
      JSX

      expect(ir.hoc_wrappers).to eq(["forwardRef"])
      expect(ir.props.map(&:name)).to eq(["children"])
    end

    it "unwraps an arrow forwardRef without an inner identifier" do
      ir = lower(<<~JSX)
        const Button = forwardRef(({ children }, ref) => <button>{children}</button>);
      JSX

      expect(ir.name).to eq("Button")
      expect(ir.hoc_wrappers).to eq(["forwardRef"])
      expect(ir.props.map(&:name)).to eq(["children"])
    end

    it "unwraps `export default memo(function X() {...})`" do
      ir = lower(<<~JSX)
        export default memo(function Greeting({ name }) { return <h1>{name}</h1>; });
      JSX

      expect(ir.name).to eq("Greeting")
      expect(ir.hoc_wrappers).to eq(["memo"])
    end

    it "flattens nested wrappers in outside-in order" do
      ir = lower(<<~JSX)
        const Button = memo(forwardRef(function Button({ label }, ref) { return <button>{label}</button>; }));
      JSX

      expect(ir.hoc_wrappers).to eq(%w[memo forwardRef])
      expect(ir.props.map(&:name)).to eq(["label"])
    end

    it "doesn't record the HOC-wrapped declaration as a module binding" do
      ir = lower(<<~JSX)
        const NoteTag = memo(function NoteTag({ label }) { return <span>{label}</span>; });
      JSX

      expect(ir.module_bindings.map(&:name)).not_to include("NoteTag")
    end

    it "leaves unrecognized wrappers alone (still no component found)" do
      expect do
        lower("const X = wrapWithMagic(function X() { return <p/>; });")
      end.to raise_error(JsxRosetta::IR::Lowering::LoweringError, /no component function/)
    end

    it "returns an empty hoc_wrappers list for non-HOC components" do
      ir = lower("function X() { return <p />; }")

      expect(ir.hoc_wrappers).to eq([])
    end
  end

  describe "B1: getServerSideProps / getStaticProps capture" do
    it "captures an exported `async function getServerSideProps(ctx)` verbatim" do
      ir = lower(<<~JSX)
        export async function getServerSideProps(ctx) {
          const { id } = ctx.params;
          return { props: { id } };
        }
        function X() { return <p />; }
      JSX

      expect(ir.server_data_source).not_to be_nil
      expect(ir.server_data_source.hook_name).to eq("getServerSideProps")
      expect(ir.server_data_source.source).to include("export async function getServerSideProps(ctx)")
      expect(ir.server_data_source.source).to include("return { props: { id } };")
    end

    it "captures the const-arrow form" do
      ir = lower(<<~JSX)
        export const getServerSideProps = async (ctx) => ({ props: { id: ctx.params.id } });
        function X() { return <p />; }
      JSX

      expect(ir.server_data_source.hook_name).to eq("getServerSideProps")
      expect(ir.server_data_source.source).to include("export const getServerSideProps")
    end

    it "captures getStaticProps in the same way" do
      ir = lower(<<~JSX)
        export async function getStaticProps() {
          return { props: { hello: "world" } };
        }
        function X() { return <p />; }
      JSX

      expect(ir.server_data_source.hook_name).to eq("getStaticProps")
    end

    it "returns nil when no hook export is present" do
      ir = lower("function X() { return <p />; }")

      expect(ir.server_data_source).to be_nil
    end

    it "captures the first hook when both are present (rare)" do
      ir = lower(<<~JSX)
        export async function getServerSideProps() { return { props: {} }; }
        export async function getStaticProps() { return { props: {} }; }
        function X() { return <p />; }
      JSX

      expect(ir.server_data_source.hook_name).to eq("getServerSideProps")
    end
  end

  describe "Gap D: render-prop / function-as-children" do
    it "lowers `<Form.List>{(fields) => <p>{fields}</p>}</Form.List>` to RenderProp" do
      ir = lower(<<~JSX)
        function X() {
          return <Form.List>{(fields) => <p>{fields}</p>}</Form.List>;
        }
      JSX

      child = ir.body.children.first
      expect(child).to be_a(JsxRosetta::IR::RenderProp)
      expect(child.params).to eq(["fields"])
      expect(child.body).to be_a(JsxRosetta::IR::Element)
      expect(child.body.tag).to eq("p")
    end

    it "captures multiple params" do
      ir = lower(<<~JSX)
        function X() {
          return <Form.List>{(fields, helpers) => <p />}</Form.List>;
        }
      JSX

      child = ir.body.children.first
      expect(child).to be_a(JsxRosetta::IR::RenderProp)
      expect(child.params).to eq(%w[fields helpers])
    end
  end

  describe "module imports" do
    it "captures `import { Foo } from 'bar'` as a named ModuleImport" do
      ir = lower(<<~JSX)
        import { Foo } from "bar";
        function X() { return <p>{Foo}</p>; }
      JSX

      expect(ir.module_imports).to include(
        JsxRosetta::IR::ModuleImport.new(name: "Foo", source: "bar", kind: :named, imported_name: "Foo")
      )
    end

    it "captures the local name when the import is renamed" do
      ir = lower(<<~JSX)
        import { foo as renamedFoo } from "bar";
        function X() { return <p>{renamedFoo}</p>; }
      JSX

      expect(ir.module_imports.map(&:name)).to include("renamedFoo")
    end

    it "captures the original exported name on a renamed import" do
      # `import { foo as renamedFoo }` — `name` is the local alias,
      # `imported_name` is the source-module export ("foo"). Backends
      # that vendor data by canonical name (e.g. Lucide SVGs) need the
      # original name even when the consumer renames the binding.
      ir = lower(<<~JSX)
        import { foo as renamedFoo } from "bar";
        function X() { return <p>{renamedFoo}</p>; }
      JSX

      renamed = ir.module_imports.find { |i| i.name == "renamedFoo" }
      expect(renamed.imported_name).to eq("foo")
    end

    it "captures default imports as :default" do
      ir = lower(<<~JSX)
        import DefaultThing from "module-b";
        function X() { return <p>{DefaultThing}</p>; }
      JSX

      expect(ir.module_imports).to include(
        JsxRosetta::IR::ModuleImport.new(name: "DefaultThing", source: "module-b", kind: :default, imported_name: nil)
      )
    end

    it "captures namespace imports as :namespace" do
      ir = lower(<<~JSX)
        import * as styles from "./X.module.css";
        function X() { return <p />; }
      JSX

      expect(ir.module_imports).to include(
        JsxRosetta::IR::ModuleImport.new(name: "styles", source: "./X.module.css", kind: :namespace, imported_name: nil)
      )
    end

    it "captures side-effect imports as nothing (no specifier name)" do
      # `import "./x"` brings no name into scope — there's nothing to record.
      ir = lower(<<~JSX)
        import "./side-effect.css";
        function X() { return <p />; }
      JSX

      expect(ir.module_imports).to eq([])
    end

    it "attaches imports identically to every component when the file has multiple" do
      ir = JsxRosetta::IR::Lowering.lower_all(JsxRosetta.parse(<<~JSX), source: <<~JSX)
        import styles from "./X.module.css";
        function A() { return <p />; }
        function B() { return <p />; }
      JSX
        import styles from "./X.module.css";
        function A() { return <p />; }
        function B() { return <p />; }
      JSX

      expect(ir.map(&:module_imports).map(&:length)).to eq([1, 1])
      expect(ir.map { |c| c.module_imports.first.name }).to eq(%w[styles styles])
    end
  end

  describe "Gap J: member-expression destructuring" do
    it "resolves `const { Content } = Layout; <Content/>` to `Layout::Content`" do
      # Without this, the lowering would treat `<Content/>` as a bare
      # component invocation and emit `ContentComponent.new` — wrong, since
      # Content is actually a sub-component of Layout.
      ir = lower(<<~JSX)
        function X() {
          const { Content, Header } = Layout;
          return <Content><Header>x</Header></Content>;
        }
      JSX

      expect(ir.body).to be_a(JsxRosetta::IR::ComponentInvocation)
      expect(ir.body.name).to eq("Layout.Content")
      expect(ir.body.children.first.name).to eq("Layout.Header")
    end
  end

  describe "polymorphic tag (asChild pattern) synthesis" do
    it "lowers `const C = cond ? Slot : \"button\"; <C {...x}>` to a Conditional" do
      ir = lower(<<~JSX)
        function Button({ asChild, rest }) {
          const Comp = asChild ? Slot.Root : "button";
          return <Comp {...rest}>x</Comp>;
        }
      JSX

      expect(ir.body).to be_a(JsxRosetta::IR::Conditional)
      expect(ir.body.test.expression).to eq("asChild")
      expect(ir.body.consequent).to be_a(JsxRosetta::IR::ComponentInvocation)
      expect(ir.body.consequent.name).to eq("Slot.Root")
      expect(ir.body.alternate).to be_a(JsxRosetta::IR::Element)
      expect(ir.body.alternate.tag).to eq("button")
    end

    it "carries spread props and children through to both branches" do
      ir = lower(<<~JSX)
        function X({ asChild, rest }) {
          const Comp = asChild ? Span : "div";
          return <Comp {...rest}>hi</Comp>;
        }
      JSX

      consequent = ir.body.consequent
      alternate = ir.body.alternate
      expect(consequent.props).to include(JsxRosetta::IR::SpreadAttribute.new(expression: "rest"))
      expect(alternate.attributes).to include(JsxRosetta::IR::SpreadAttribute.new(expression: "rest"))
      expect(consequent.children).to include(JsxRosetta::IR::Text.new(value: "hi"))
      expect(alternate.children).to include(JsxRosetta::IR::Text.new(value: "hi"))
    end

    it "does not record a polymorphic-tag binding in local_bindings (no double TODO)" do
      ir = lower(<<~JSX)
        function X({ asChild }) {
          const Comp = asChild ? Slot : "div";
          return <Comp />;
        }
      JSX

      expect(ir.local_bindings).to eq([])
    end
  end

  describe "Stimulus handler promotion" do
    it "promotes inline arrow handlers to StimulusBinding + StimulusMethod" do
      ir = lower("function X() { return <button onClick={() => doStuff()}>x</button>; }")

      attr = ir.body.attributes.first
      expect(attr).to be_a(JsxRosetta::IR::StimulusBinding)
      expect(attr.event).to eq("click")
      expect(attr.method_name).to eq("clickHandler")
      expect(ir.stimulus_methods.size).to eq(1)
      expect(ir.stimulus_methods.first.name).to eq("clickHandler")
      expect(ir.stimulus_methods.first.body_source).to eq("doStuff()")
    end

    it "promotes a const-bound arrow when referenced as an event handler" do
      ir = lower(<<~JSX)
        function X() {
          const handleClick = () => doStuff();
          return <button onClick={handleClick}>x</button>;
        }
      JSX

      attr = ir.body.attributes.first
      expect(attr).to be_a(JsxRosetta::IR::StimulusBinding)
      expect(attr.method_name).to eq("handleClick")
      expect(ir.stimulus_methods.first.name).to eq("handleClick")
    end

    it "promotes prop-bound event handlers (onClick={propRef}) to Stimulus methods" do
      # A bare prop reference as an event handler has no useful EventBinding
      # rendering — `data-action="<%= @on_click %>"` isn't a valid Stimulus
      # action descriptor. Promoting to Stimulus generates a method whose
      # body documents the original prop reference.
      ir = lower("function X({ onClick }) { return <button onClick={onClick}>x</button>; }")

      attr = ir.body.attributes.first
      expect(attr).to be_a(JsxRosetta::IR::StimulusBinding)
      expect(attr.method_name).to eq("onClick")
      expect(ir.stimulus_methods.first.name).to eq("onClick")
      expect(ir.stimulus_methods.first.body_source).to include("originally bound to: onClick")
    end

    it "uniquifies method names when multiple inline handlers share an event" do
      ir = lower(<<~JSX)
        function X() {
          return (
            <div>
              <button onClick={() => a()}>a</button>
              <button onClick={() => b()}>b</button>
            </div>
          );
        }
      JSX

      method_names = ir.stimulus_methods.map(&:name)
      expect(method_names).to eq(%w[clickHandler clickHandler2])
    end

    it "records the original (pre-uniquification) name on each StimulusMethod" do
      # When two handlers share a base name, both retain the original
      # base name in `original_name`. Backends use this to emit a
      # collision marker in the generated controller JS so the silent
      # rename is visible to the human reviewer.
      ir = lower(<<~JSX)
        function X({ handleReset }) {
          return (
            <div>
              <button onClick={handleReset}>a</button>
              <button onClick={handleReset}>b</button>
            </div>
          );
        }
      JSX

      methods = ir.stimulus_methods
      expect(methods.map(&:name)).to eq(%w[handleReset handleReset2])
      expect(methods.map(&:original_name)).to eq(%w[handleReset handleReset])
    end

    it "does NOT promote on*={...} to Stimulus when the tag is a component (PascalCase)" do
      # Stimulus action descriptors only fire on real DOM events. A
      # `data-action="change->foo#h"` on a Ruby component invocation
      # would never trigger — the receiving component must explicitly
      # accept the prop and decide what to do with it.
      ir = lower("function X({ onChange }) { return <Select onChange={onChange} />; }")

      attr = ir.body.props.first
      expect(attr).to be_a(JsxRosetta::IR::Attribute)
      expect(attr.name).to eq("onChange")
      expect(ir.stimulus_methods).to eq([])
    end

    it "does NOT promote on*={...} to Stimulus when the tag is a member-expression component" do
      ir = lower("function X({ onSubmit }) { return <Form.Root onSubmit={onSubmit} />; }")

      attr = ir.body.props.first
      expect(attr).to be_a(JsxRosetta::IR::Attribute)
      expect(attr.name).to eq("onSubmit")
      expect(ir.stimulus_methods).to eq([])
    end

    it "still promotes on*={...} to Stimulus when the tag is a lowercase HTML element" do
      ir = lower("function X({ onClick }) { return <button onClick={onClick} />; }")

      attr = ir.body.attributes.first
      expect(attr).to be_a(JsxRosetta::IR::StimulusBinding)
    end
  end

  describe "conditionals" do
    it "lowers {cond && X} to IR::Conditional with no alternate" do
      ir = lower("function X({ open }) { return <div>{open && <p>shown</p>}</div>; }")

      cond = ir.body.children.first
      expect(cond).to be_a(JsxRosetta::IR::Conditional)
      expect(cond.test).to eq(JsxRosetta::IR::Interpolation.new(expression: "open"))
      expect(cond.consequent).to be_a(JsxRosetta::IR::Element)
      expect(cond.alternate).to be_nil
    end

    it "lowers {cond ? X : null} with no alternate" do
      ir = lower("function X({ open }) { return <div>{open ? <p /> : null}</div>; }")

      cond = ir.body.children.first
      expect(cond.alternate).to be_nil
      expect(cond.consequent).to be_a(JsxRosetta::IR::Element)
    end

    it "lowers {cond ? X : Y} with both branches" do
      ir = lower("function X({ open }) { return <div>{open ? <a /> : <b />}</div>; }")

      cond = ir.body.children.first
      expect(cond.consequent).to be_a(JsxRosetta::IR::Element)
      expect(cond.consequent.tag).to eq("a")
      expect(cond.alternate).to be_a(JsxRosetta::IR::Element)
      expect(cond.alternate.tag).to eq("b")
    end

    it "leaves || and ?? logical expressions as opaque interpolations" do
      ir = lower("function X({ a, b }) { return <div>{a || b}</div>; }")

      expect(ir.body.children.first).to be_a(JsxRosetta::IR::Interpolation)
    end

    it "lowers a top-level ternary return to IR::Conditional" do
      ir = lower("function X({ open }) { return open ? <a /> : <b />; }")

      expect(ir.body).to be_a(JsxRosetta::IR::Conditional)
      expect(ir.body.test).to eq(JsxRosetta::IR::Interpolation.new(expression: "open"))
      expect(ir.body.consequent).to be_a(JsxRosetta::IR::Element)
      expect(ir.body.consequent.tag).to eq("a")
      expect(ir.body.alternate).to be_a(JsxRosetta::IR::Element)
      expect(ir.body.alternate.tag).to eq("b")
    end

    it "lowers a top-level `cond && JSX` return to IR::Conditional with no alternate" do
      ir = lower("function X({ visible }) { return visible && <p />; }")

      expect(ir.body).to be_a(JsxRosetta::IR::Conditional)
      expect(ir.body.alternate).to be_nil
      expect(ir.body.consequent).to be_a(JsxRosetta::IR::Element)
    end

    it "lowers a multi-branch if/else-if/else of all-return branches to a Conditional chain" do
      ir = lower(<<~JS)
        function X({ kind }) {
          if (kind === "a") {
            return <a />;
          } else if (kind === "b") {
            return <b />;
          } else {
            return <c />;
          }
        }
      JS

      cond = ir.body
      expect(cond).to be_a(JsxRosetta::IR::Conditional)
      expect(cond.consequent).to be_a(JsxRosetta::IR::Element)
      expect(cond.consequent.tag).to eq("a")

      else_if = cond.alternate
      expect(else_if).to be_a(JsxRosetta::IR::Conditional)
      expect(else_if.consequent.tag).to eq("b")
      expect(else_if.alternate).to be_a(JsxRosetta::IR::Element)
      expect(else_if.alternate.tag).to eq("c")
    end

    it "lowers a brace-less if/else of bare returns" do
      ir = lower("function X({ open }) { if (open) return <a />; else return <b />; }")

      expect(ir.body).to be_a(JsxRosetta::IR::Conditional)
      expect(ir.body.consequent.tag).to eq("a")
      expect(ir.body.alternate.tag).to eq("b")
    end

    it "silently drops side-effect statements preceding a branch's return (matches outer-block behavior)" do
      jsx = "function X({ kind }) { if (kind) { sideEffect(); return <a />; } else { return <b />; } }"
      ir = lower(jsx)

      expect(ir.body).to be_a(JsxRosetta::IR::Conditional)
      expect(ir.body.consequent.tag).to eq("a")
      expect(ir.body.alternate.tag).to eq("b")
    end
  end

  describe "return shapes (NullLiteral, Identifier, CallExpression)" do
    it "lowers `return null;` to an empty Text node" do
      ir = lower("function X() { return null; }")

      expect(ir.body).to eq(JsxRosetta::IR::Text.new(value: ""))
    end

    it "lowers `if (x) return <A/>; return null;` to a Conditional with empty alternate" do
      ir = lower("function X({ loading }) { if (loading) return <Skeleton />; return null; }")

      expect(ir.body).to be_a(JsxRosetta::IR::Conditional)
      expect(ir.body.consequent).to be_a(JsxRosetta::IR::ComponentInvocation)
      expect(ir.body.consequent.name).to eq("Skeleton")
      expect(ir.body.alternate).to eq(JsxRosetta::IR::Text.new(value: ""))
    end

    it "lowers `return cardIdentifier;` to an Interpolation of the identifier" do
      ir = lower("function X({ card }) { return card; }")

      expect(ir.body).to eq(JsxRosetta::IR::Interpolation.new(expression: "card"))
    end

    it "inlines a JSX-bound local identifier in return position" do
      ir = lower("function X() { const card = <p>hi</p>; return card; }")

      expect(ir.body).to be_a(JsxRosetta::IR::Element)
      expect(ir.body.tag).to eq("p")
    end

    it "lowers `return computeValue(row);` to an Interpolation of the call expression" do
      ir = lower("function X({ row }) { return computeValue(row); }")

      expect(ir.body).to eq(JsxRosetta::IR::Interpolation.new(expression: "computeValue(row)"))
    end

    it "lowers `if (href) return <Link>{children}</Link>; return children;` to a Conditional with Slot alternate" do
      source = "function X({ href, children }) { if (href) return <Link>{children}</Link>; return children; }"
      ir = lower(source)

      expect(ir.body).to be_a(JsxRosetta::IR::Conditional)
      expect(ir.body.consequent).to be_a(JsxRosetta::IR::ComponentInvocation)
      # `children` in return position; @local_jsx isn't set up for params, so it falls through to Interpolation
      expect(ir.body.alternate).to be_a(JsxRosetta::IR::Interpolation)
    end
  end

  describe "switch return chains" do
    it "lowers a switch with bare-return cases and a default to a nested Conditional" do
      ir = lower(<<~JS)
        function X({ kind }) {
          switch (kind) {
            case "a":
              return <a />;
            case "b":
              return <b />;
            default:
              return <c />;
          }
        }
      JS

      cond = ir.body
      expect(cond).to be_a(JsxRosetta::IR::Conditional)
      expect(cond.test.expression).to eq('kind === "a"')
      expect(cond.consequent.tag).to eq("a")

      inner = cond.alternate
      expect(inner).to be_a(JsxRosetta::IR::Conditional)
      expect(inner.test.expression).to eq('kind === "b"')
      expect(inner.consequent.tag).to eq("b")
      expect(inner.alternate.tag).to eq("c")
    end

    it "lowers a switch without a default to a Conditional whose final alternate is empty Text" do
      ir = lower(<<~JS)
        function X({ kind }) {
          switch (kind) {
            case "a":
              return <a />;
          }
        }
      JS

      cond = ir.body
      expect(cond).to be_a(JsxRosetta::IR::Conditional)
      expect(cond.alternate).to eq(JsxRosetta::IR::Text.new(value: ""))
    end

    it "lowers a switch with block-wrapped return cases" do
      ir = lower(<<~JS)
        function X({ kind }) {
          switch (kind) {
            case "a": { return <a />; }
            default: { return <c />; }
          }
        }
      JS

      expect(ir.body).to be_a(JsxRosetta::IR::Conditional)
      expect(ir.body.consequent.tag).to eq("a")
      expect(ir.body.alternate.tag).to eq("c")
    end

    it "ORs the tests for fall-through cases sharing a return value" do
      ir = lower(<<~JS)
        function X({ kind }) {
          switch (kind) {
            case "a":
            case "b":
              return <ab />;
            default:
              return <c />;
          }
        }
      JS

      expect(ir.body.test.expression).to eq('kind === "a" || kind === "b"')
      expect(ir.body.consequent.tag).to eq("ab")
      expect(ir.body.alternate.tag).to eq("c")
    end

    it "silently drops preceding side-effect expressions in a case body (pragmatic match to outer-block behavior)" do
      ir = lower(<<~JS)
        function X({ kind }) {
          switch (kind) {
            case "a":
              sideEffect();
              return <a />;
          }
        }
      JS

      expect(ir.body).to be_a(JsxRosetta::IR::Conditional)
      expect(ir.body.consequent.tag).to eq("a")
    end

    it "raises when a switch case has no return at all (only side effects + break)" do
      jsx = <<~JS
        function X({ kind }) {
          switch (kind) {
            case "a":
              sideEffect();
              break;
          }
        }
      JS
      expect { lower(jsx) }.to raise_error(JsxRosetta::IR::Lowering::LoweringError, /no return statement/)
    end

    it "lowers a case with leading var-decls + return to a Conditional that absorbs the binding" do
      ir = lower(<<~JS)
        function X({ kind, record }) {
          switch (kind) {
            case "money": {
              const money = record.money;
              return <MoneyFormItem money={money} />;
            }
            default: return <p />;
          }
        }
      JS

      expect(ir.body).to be_a(JsxRosetta::IR::Conditional)
      expect(ir.body.consequent).to be_a(JsxRosetta::IR::ComponentInvocation)
      expect(ir.body.consequent.name).to eq("MoneyFormItem")
      expect(ir.local_bindings.map(&:name)).to include("money")
    end

    it "wraps a leading `if (X) return Y;` guard around a trailing switch" do
      ir = lower(<<~JS)
        function X({ value, kind }) {
          if (!value) return <NilValue />;
          switch (kind) {
            case "a": return <a />;
            default: return <b />;
          }
        }
      JS

      expect(ir.body).to be_a(JsxRosetta::IR::Conditional)
      expect(ir.body.test.expression).to eq("!value")
      expect(ir.body.consequent).to be_a(JsxRosetta::IR::ComponentInvocation)
      expect(ir.body.consequent.name).to eq("NilValue")
      expect(ir.body.alternate).to be_a(JsxRosetta::IR::Conditional)
    end
  end

  describe "try return chains" do
    it "lowers a `try { return <X/>; }` to the try block's return value" do
      ir = lower(<<~JS)
        function X() {
          try {
            return <a />;
          } catch (e) {
            console.error(e);
          }
        }
      JS

      expect(ir.body).to be_a(JsxRosetta::IR::Element)
      expect(ir.body.tag).to eq("a")
    end

    it "raises when the try block has no recognizable return" do
      jsx = "function X() { try { sideEffect(); } catch (e) {} }"
      expect { lower(jsx) }.to raise_error(JsxRosetta::IR::Lowering::LoweringError, /no return statement/)
    end
  end

  describe "module-shape classifier (error-message UX)" do
    it "labels a hooks-only module with a behavior-vs-state hint" do
      expect { lower("export function useThing() { const [s, setS] = useState(0); return s; }") }
        .to raise_error(JsxRosetta::IR::Lowering::LoweringError, /custom-hooks module.*Stimulus controller/)
    end

    it "labels a utility module that has no JSX-returning helpers" do
      expect { lower("export function formatThing(x) { return x.toString(); }") }
        .to raise_error(JsxRosetta::IR::Lowering::LoweringError, /utility module.*JSX-returning/)
    end

    it "still labels a class-component module when there's no render method" do
      # v0.5.0 added a ClassDeclaration → ViewComponent path for classes
      # WITH a `render()` method, but classes lacking render still can't
      # translate — surface the original triage label.
      expect { lower("export class MyComp extends React.Component { other() { return 1; } }") }
        .to raise_error(JsxRosetta::IR::Lowering::LoweringError, /class component.*function components/)
    end

    it "lowers a class component that defines a render() method (v0.5.0 path)" do
      ir = lower(<<~JSX)
        class MyComp extends React.Component {
          render() {
            const { type } = this.props;
            return <div className={type} />;
          }
        }
      JSX

      expect(ir).to be_a(JsxRosetta::IR::Component)
      expect(ir.name).to eq("MyComp")
      expect(ir.props.map(&:name)).to include("type")
      expect(ir.body).to be_a(JsxRosetta::IR::Element)
    end

    it "captures non-render class members as LocalBinding TODOs" do
      ir = lower(<<~JSX)
        class MyComp extends React.Component {
          constructor(props) { super(props); this.state = { x: 0 }; }
          componentDidMount() { console.log("mounted"); }
          render() { return <div />; }
        }
      JSX

      bound_names = ir.local_bindings.map(&:name)
      expect(bound_names).to include("constructor", "componentDidMount")
      expect(ir.local_bindings.map(&:source).join).to include("super(props)")
    end

    it "synthesizes props from direct `this.props.X` access in a class render" do
      ir = lower(<<~JSX)
        class Card extends React.Component {
          render() {
            return <div>{this.props.title}</div>;
          }
        }
      JSX

      expect(ir.props.map(&:name)).to include("title")
    end

    it "lowers a data-factory function whose body returns an array of object literals" do
      ir = lower(<<~JS)
        export const createColumns = (token, sortedInfo) => [
          { title: "Name", dataIndex: "name", width: 200 }
        ];
      JS

      expect(ir).to be_a(JsxRosetta::IR::Component)
      expect(ir.name).to eq("createColumns")
      expect(ir.mode).to eq(:data_factory)
      expect(ir.body).to be_a(JsxRosetta::IR::ArrayLiteral)
      expect(ir.props.map(&:name)).to eq(%w[token sortedInfo])
    end

    it "does not treat a body returning a primitive array as a data factory" do
      # `[1, 2, 3]` is not column-descriptor-shaped; the existing utility-
      # module rejection should still fire.
      expect { lower("export const constants = () => [1, 2, 3];") }
        .to raise_error(JsxRosetta::IR::Lowering::LoweringError, /utility module/)
    end

    it "labels a columns/data module (top-level array literal export)" do
      expect { lower("export const columns = [{ title: 'Name' }, { title: 'Age' }];") }
        .to raise_error(JsxRosetta::IR::Lowering::LoweringError, /data export.*not a component/)
    end

    it "labels a HOC-wrapped component when the wrapper isn't peelable (React.lazy)" do
      # `React.memo` / `forwardRef` / `observer` etc. now peel through to
      # the inner component. `React.lazy(() => import(...))` carries no
      # inline function body to lower — the wrapper-detection shape
      # classifier still fires for it.
      expect { lower("export const X = React.lazy(() => import('./X'));") }
        .to raise_error(JsxRosetta::IR::Lowering::LoweringError, /HOC-wrapped component/)
    end

    it "labels a types-only module" do
      source = "export type Foo = { a: 1 };"
      ast = JsxRosetta.parse(source, typescript: true)
      expect { JsxRosetta::IR::Lowering.lower(ast, source: source) }
        .to raise_error(JsxRosetta::IR::Lowering::LoweringError, %r{types/constants module})
    end

    it "labels a mixed-exports module (some hooks + some non-hook helpers)" do
      source = <<~JS
        export const splitExtension = (s) => s.split(".");
        export const useFilenameEditor = ({}) => { return ""; };
      JS
      expect { lower(source) }.to raise_error(JsxRosetta::IR::Lowering::LoweringError, /mixes shapes/)
    end

    it "leaves the suffix off when nothing matches" do
      expect { lower("import x from 'y';") }
        .to raise_error(JsxRosetta::IR::Lowering::LoweringError) do |error|
          expect(error.message).not_to include("looks like a")
          expect(error.message).to include("no component function found in module")
        end
    end
  end

  describe "lowercase-named JSX-returning helpers" do
    it "treats a lowercase function whose body returns JSX as a component" do
      ir = lower("export const textRender = (value) => { if (!value) return value; return <NilValue />; };")

      expect(ir).to be_a(JsxRosetta::IR::Component)
      expect(ir.name).to eq("textRender")
    end

    it "treats a lowercase function with implicit JSX return as a component" do
      ir = lower("export const renderTag = () => <Tag />;")

      expect(ir).to be_a(JsxRosetta::IR::Component)
      expect(ir.name).to eq("renderTag")
      expect(ir.body).to be_a(JsxRosetta::IR::ComponentInvocation)
    end

    it "lifts a switch-with-JSX-cases lowercase function as a component" do
      ir = lower(<<~JS)
        export const cellFor = (kind) => {
          switch (kind) {
            case "name": return <NameCell />;
            default: return <DefaultCell />;
          }
        };
      JS

      expect(ir).to be_a(JsxRosetta::IR::Component)
      expect(ir.body).to be_a(JsxRosetta::IR::Conditional)
    end

    it "still rejects a lowercase function whose body returns no JSX" do
      expect { lower("export const formatThing = (x) => x.toString();") }
        .to raise_error(JsxRosetta::IR::Lowering::LoweringError, /no component function found/)
    end

    it "still rejects a `use*` hook even when the hook body would technically render JSX" do
      # Defensive: prevents accidental component-translation of hooks whose
      # name signals they return data, not view markup.
      expect { lower("export const useThing = () => <p />;") }
        .to raise_error(JsxRosetta::IR::Lowering::LoweringError, /no component function found/)
    end

    it "lowers a multi-helper file picking the first JSX-returning one" do
      source = <<~JS
        export const textRender = (v) => v ? v : <NilValue />;
        export const booleanRender = (v) => v ? "Yes" : <NilValue />;
      JS
      ir = lower(source)

      expect(ir).to be_a(JsxRosetta::IR::Component)
      expect(ir.name).to eq("textRender")
    end
  end

  describe "return shapes — non-JSX expressions" do
    it "lowers `return memberExpr;` to an Interpolation of the verbatim source" do
      ir = lower("function X({ money }) { return money.formattedValue; }")

      expect(ir.body).to eq(JsxRosetta::IR::Interpolation.new(expression: "money.formattedValue"))
    end

    it "lowers `return 'literal';` to Text" do
      ir = lower("function X() { return 'hello'; }")

      expect(ir.body).to eq(JsxRosetta::IR::Text.new(value: "hello"))
    end

    it "lowers `return 42;` to Text of the stringified number" do
      ir = lower("function X() { return 42; }")

      expect(ir.body).to eq(JsxRosetta::IR::Text.new(value: "42"))
    end

    it "lowers `return template literals` to Interpolation" do
      ir = lower("function X({ name }) { return `hello ${name}`; }")

      expect(ir.body).to be_a(JsxRosetta::IR::Interpolation)
    end
  end

  describe "loops" do
    it "lowers items.map((item) => <X />) to IR::Loop" do
      ir = lower("function X({ items }) { return <ul>{items.map((item) => <li />)}</ul>; }")

      loop_node = ir.body.children.first
      expect(loop_node).to be_a(JsxRosetta::IR::Loop)
      expect(loop_node.iterable).to eq(JsxRosetta::IR::Interpolation.new(expression: "items"))
      expect(loop_node.item_binding).to eq("item")
      expect(loop_node.index_binding).to be_nil
      expect(loop_node.body).to be_a(JsxRosetta::IR::Element)
      expect(loop_node.body.tag).to eq("li")
    end

    it "captures the index binding when present" do
      ir = lower("function X({ items }) { return <ul>{items.map((item, i) => <li />)}</ul>; }")

      expect(ir.body.children.first.index_binding).to eq("i")
    end

    it "supports a block-bodied arrow function with a return" do
      jsx = "function X({ items }) { return <ul>{items.map((item) => { return <li />; })}</ul>; }"
      ir = lower(jsx)

      expect(ir.body.children.first).to be_a(JsxRosetta::IR::Loop)
    end

    it "leaves non-map call expressions as opaque interpolations" do
      ir = lower("function X({ items }) { return <p>{items.length}</p>; }")

      expect(ir.body.children.first).to be_a(JsxRosetta::IR::Interpolation)
    end
  end

  describe "fragments" do
    it "lowers a JSX fragment to IR::Fragment" do
      ir = lower("function X() { return <><Button /></>; }")

      expect(ir.body).to be_a(JsxRosetta::IR::Fragment)
      expect(ir.body.children.first).to be_a(JsxRosetta::IR::ComponentInvocation)
    end
  end

  describe "props" do
    it "lowers destructured props with no defaults" do
      ir = lower("function X({ a, b }) { return <div />; }")

      expect(ir.props).to eq([
                               JsxRosetta::IR::Prop.new(name: "a", default: nil, alias_name: nil),
                               JsxRosetta::IR::Prop.new(name: "b", default: nil, alias_name: nil)
                             ])
    end

    it "lowers destructured props with defaults to Interpolation defaults" do
      ir = lower('function X({ variant = "primary", size = 4 }) { return <div />; }')

      expect(ir.props).to eq([
                               JsxRosetta::IR::Prop.new(
                                 name: "variant",
                                 default: JsxRosetta::IR::Interpolation.new(expression: '"primary"'),
                                 alias_name: nil
                               ),
                               JsxRosetta::IR::Prop.new(
                                 name: "size",
                                 default: JsxRosetta::IR::Interpolation.new(expression: "4"),
                                 alias_name: nil
                               )
                             ])
    end

    it "lowers a single-identifier params bag" do
      ir = lower("function X(props) { return <div />; }")

      expect(ir.props).to eq([JsxRosetta::IR::Prop.new(name: "props", default: nil, alias_name: nil)])
    end

    it "captures the rest-binding name into rest_prop_name and excludes it from props" do
      ir = lower("function X({ a, ...rest }) { return <div />; }")

      expect(ir.props).to eq([JsxRosetta::IR::Prop.new(name: "a", default: nil, alias_name: nil)])
      expect(ir.rest_prop_name).to eq("rest")
    end

    it "leaves rest_prop_name nil when there is no rest binding" do
      ir = lower("function X({ a }) { return <div />; }")

      expect(ir.rest_prop_name).to be_nil
    end

    it "lowers a nested-destructured prop using the outer key as the prop name" do
      ir = lower("function X({ record: { claimNumber, claim }, accountSlug }) { return <div />; }")

      expect(ir.props).to eq([
                               JsxRosetta::IR::Prop.new(name: "record", default: nil, alias_name: nil),
                               JsxRosetta::IR::Prop.new(name: "accountSlug", default: nil, alias_name: nil)
                             ])
    end

    it "lowers a renamed-destructured prop using the source-side key" do
      ir = lower("function X({ outer: inner }) { return <div />; }")

      expect(ir.props).to eq([JsxRosetta::IR::Prop.new(name: "outer", default: nil, alias_name: "inner")])
    end

    it "lowers a StringLiteral destructure key (e.g. `data-testid`)" do
      ir = lower('function X({ "data-testid": testId }) { return <div data-testid={testId} />; }')

      expect(ir.props).to eq([JsxRosetta::IR::Prop.new(name: "data-testid", default: nil, alias_name: "testId")])
    end

    it "lowers a StringLiteral destructure key with a default" do
      ir = lower('function X({ "data-testid": testId = "x" }) { return <div />; }')

      expect(ir.props).to eq([
                               JsxRosetta::IR::Prop.new(
                                 name: "data-testid",
                                 default: JsxRosetta::IR::Interpolation.new(expression: '"x"'),
                                 alias_name: "testId"
                               )
                             ])
    end

    it "round-trips a StringLiteral destructure key through the backend as a snake_case kwarg" do
      source = 'function FlashyHeader({ "data-testid": dataTestId }) { return <h1 data-testid={dataTestId}>x</h1>; }'
      backend = JsxRosetta::Backend::ViewComponent.new(layout: :flat)
      files = backend.emit(lower(source)).to_h { |f| [f.path, f.contents] }

      expect(files["flashy_header_component.rb"]).to include("data_testid: nil")
      expect(files["flashy_header_component.rb"]).to include("@data_testid = data_testid")
      expect(files["flashy_header_component.html.erb"]).to include("data-testid=")
    end
  end

  describe "cn / clsx className lowering" do
    it "lowers `className={cn(\"a\", \"b\")}` to a ClassList of literal segments" do
      ir = lower('function X() { return <div className={cn("a", "b")} />; }')

      expect(ir.body.attributes).to eq([JsxRosetta::IR::ClassList.new(segments: %w[a b])])
    end

    it "lowers identifier arguments to IR::Interpolation segments" do
      ir = lower("function X({ extra }) { return <div className={cn(\"base\", extra)} />; }")

      class_list = ir.body.attributes.first
      expect(class_list).to be_a(JsxRosetta::IR::ClassList)
      expect(class_list.segments).to eq([
                                          "base",
                                          JsxRosetta::IR::Interpolation.new(expression: "extra")
                                        ])
    end

    it "lowers object-literal arguments to ConditionalSegment entries" do
      ir = lower('function X({ on }) { return <div className={cn("base", { "active": on, "done": !on })} />; }')

      class_list = ir.body.attributes.first
      expect(class_list).to be_a(JsxRosetta::IR::ClassList)
      expect(class_list.segments[1]).to eq(
        JsxRosetta::IR::ConditionalSegment.new(
          class_name: "active",
          condition: JsxRosetta::IR::Interpolation.new(expression: "on")
        )
      )
      expect(class_list.segments[2]).to eq(
        JsxRosetta::IR::ConditionalSegment.new(
          class_name: "done",
          condition: JsxRosetta::IR::Interpolation.new(expression: "!on")
        )
      )
    end

    it "recognizes clsx and classnames callers as well" do
      ir = lower('function X() { return <div className={clsx("a")} />; }')
      expect(ir.body.attributes.first).to be_a(JsxRosetta::IR::ClassList)

      ir = lower('function X() { return <div className={classnames("a")} />; }')
      expect(ir.body.attributes.first).to be_a(JsxRosetta::IR::ClassList)
    end

    it "falls back to StyleBinding when an argument shape is unsupported" do
      ir = lower('function X() { return <div className={cn("a", computeOther())} />; }')

      expect(ir.body.attributes.first).to be_a(JsxRosetta::IR::StyleBinding)
    end
  end

  describe "inline styles" do
    it "lowers `style={{ fontSize: 12, color: \"red\" }}` to IR::Style with `px` for unit-bearing numerics" do
      ir = lower('function X() { return <div style={{ fontSize: 12, color: "red" }} />; }')

      expect(ir.body.attributes).to eq([
                                         JsxRosetta::IR::Style.new(
                                           declarations: [
                                             JsxRosetta::IR::StyleDeclaration.new(property: "font-size", value: "12px"),
                                             JsxRosetta::IR::StyleDeclaration.new(property: "color", value: "red")
                                           ]
                                         )
                                       ])
    end

    it "leaves unitless properties (e.g. `zIndex`, `lineHeight`, `opacity`) bare" do
      # React's isUnitlessNumber table — these properties take a bare
      # number, not a length.
      ir = lower("function X() { return <div style={{ zIndex: 5, lineHeight: 1.4, opacity: 0.5 }} />; }")

      values = ir.body.attributes.first.declarations.map(&:value)
      expect(values).to eq(%w[5 1.4 0.5])
    end

    it "leaves 0 bare (no `0px` clutter — `0` is unitless in CSS)" do
      ir = lower("function X() { return <div style={{ marginBottom: 0 }} />; }")

      expect(ir.body.attributes.first.declarations.first.value).to eq("0")
    end

    it "lowers identifier values to IR::Interpolation in StyleDeclaration" do
      ir = lower("function X({ size }) { return <div style={{ fontSize: size }} />; }")

      decl = ir.body.attributes.first.declarations.first
      expect(decl.property).to eq("font-size")
      expect(decl.value).to eq(JsxRosetta::IR::Interpolation.new(expression: "size"))
    end

    it "falls back to a plain Attribute when an inline-style value shape is unsupported" do
      ir = lower("function X() { return <div style={{ fontSize: computeSize() }} />; }")

      expect(ir.body.attributes.first).to be_a(JsxRosetta::IR::Attribute)
      expect(ir.body.attributes.first.name).to eq("style")
    end
  end

  describe "spread attributes" do
    it "lowers `{...rest}` to IR::SpreadAttribute on an Element" do
      ir = lower("function X({ rest }) { return <div {...rest} />; }")

      expect(ir.body.attributes).to eq([JsxRosetta::IR::SpreadAttribute.new(expression: "rest")])
    end

    it "lowers `{...rest}` to IR::SpreadAttribute on a ComponentInvocation" do
      ir = lower("function X({ rest }) { return <Inner {...rest} />; }")

      expect(ir.body.props).to eq([JsxRosetta::IR::SpreadAttribute.new(expression: "rest")])
    end
  end

  describe "exported components" do
    it "finds a function inside an ExportNamedDeclaration" do
      ir = lower("export function Greeting() { return <p>Hi</p>; }")

      expect(ir.name).to eq("Greeting")
    end

    it "finds a function inside an ExportDefaultDeclaration" do
      ir = lower("export default function Greeting() { return <p>Hi</p>; }")

      expect(ir.name).to eq("Greeting")
    end
  end

  describe "skipping non-component top-level functions" do
    it "skips lowercase-named functions (React convention: hooks are camelCase, helpers lowercase)" do
      source = <<~JSX
        function useCarousel() { return context; }
        function Carousel({ children }) { return <div>{children}</div>; }
      JSX

      ir = JsxRosetta::IR.lower_all(JsxRosetta.parse(source), source: source)
      expect(ir.map(&:name)).to eq(["Carousel"])
    end

    it "skips lowercase const-bound arrows alongside PascalCase ones" do
      source = <<~JSX
        const useFormField = () => ({});
        const Form = () => <form />;
      JSX

      ir = JsxRosetta::IR.lower_all(JsxRosetta.parse(source), source: source)
      expect(ir.map(&:name)).to eq(["Form"])
    end
  end

  describe "arrow-function components" do
    it "lowers `const X = () => { return <jsx>; }`" do
      ir = lower("const Greeting = () => { return <p>Hi</p>; };")

      expect(ir.name).to eq("Greeting")
      expect(ir.body.tag).to eq("p")
    end

    it "lowers `const X = () => <jsx>` (implicit return)" do
      ir = lower("const Greeting = () => <p>Hi</p>;")

      expect(ir.name).to eq("Greeting")
      expect(ir.body.tag).to eq("p")
    end

    it "lowers an exported arrow-function component" do
      ir = lower("export const Greeting = ({ who }) => <p>Hi {who}</p>;")

      expect(ir.name).to eq("Greeting")
      expect(ir.props.map(&:name)).to eq(["who"])
    end

    it "lowers a function-expression assigned to a const" do
      ir = lower("const Greeting = function () { return <p>Hi</p>; };")

      expect(ir.name).to eq("Greeting")
    end
  end

  describe "Button fixture (full IR equality)" do
    it "lowers the Button fixture to the expected IR tree" do
      source = File.read(File.expand_path("../fixtures/jsx/button.jsx", __dir__))

      ir = described_class.lower(JsxRosetta.parse(source), source: source)

      expected = JsxRosetta::IR::Component.new(
        name: "Button",
        props: [
          JsxRosetta::IR::Prop.new(name: "children", default: nil, alias_name: nil),
          JsxRosetta::IR::Prop.new(name: "onClick", default: nil, alias_name: nil),
          JsxRosetta::IR::Prop.new(
            name: "variant",
            default: JsxRosetta::IR::Interpolation.new(expression: '"primary"'),
            alias_name: nil
          )
        ],
        body: JsxRosetta::IR::Element.new(
          tag: "button",
          attributes: [
            JsxRosetta::IR::Attribute.new(name: "type", value: "button"),
            JsxRosetta::IR::StyleBinding.new(expression: "`btn btn-${variant}`"),
            JsxRosetta::IR::StimulusBinding.new(event: "click", method_name: "onClick")
          ],
          children: [
            JsxRosetta::IR::Slot.new(name: "children")
          ]
        ),
        rest_prop_name: nil,
        local_bindings: [],
        local_binding_names: [],
        module_bindings: [],
        module_imports: [
          JsxRosetta::IR::ModuleImport.new(name: "React", source: "react", kind: :default, imported_name: nil)
        ],
        stimulus_methods: [
          JsxRosetta::IR::StimulusMethod.new(
            name: "onClick",
            body_source: "// originally bound to: onClick",
            original_name: "onClick",
            params: [],
            body_is_block: false
          )
        ],
        react_hooks: [],
        render_methods: [],
        mode: :view,
        server_data_source: nil,
        hoc_wrappers: []
      )

      expect(ir).to eq(expected)
    end
  end

  describe "errors" do
    it "raises a LoweringError when there is no component function" do
      expect { lower("const x = 1;") }.to raise_error(JsxRosetta::IR::Lowering::LoweringError)
    end

    it "raises a LoweringError when the function has no return statement" do
      expect do
        lower("function X() { console.log('hi'); }")
      end.to raise_error(JsxRosetta::IR::Lowering::LoweringError, /line \d+/)
    end

    it "includes line and column on the error when a node anchors the failure" do
      source = "function X(...weird) {\n  return <p />;\n}"
      expect { described_class.lower(JsxRosetta.parse(source), source: source) }
        .to raise_error(JsxRosetta::IR::Lowering::LoweringError) do |error|
          expect(error.line).to eq(1)
          expect(error.column).to be > 0
          expect(error.message).to match(/line 1, column \d+/)
        end
    end
  end
end
