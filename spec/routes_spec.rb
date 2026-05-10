# frozen_string_literal: true

RSpec.describe JsxRosetta::Routes do
  def lower(source)
    described_class.lower(JsxRosetta.parse(source))
  end

  it "extracts <Route path=\"…\" element={<X />} /> entries" do
    tree = lower(<<~JSX)
      function App() {
        return (
          <Routes>
            <Route path="/" element={<Home />} />
            <Route path="/posts" element={<PostsIndex />} />
            <Route path="/posts/:id" element={<PostShow />} />
          </Routes>
        );
      }
    JSX

    expect(tree.routes.map(&:path)).to eq(["/", "/posts", "/posts/:id"])
    expect(tree.routes.map(&:element_name)).to eq(%w[Home PostsIndex PostShow])
  end

  it "flattens member-expression elements to the rightmost name" do
    tree = lower('function App() { return <Route path="/" element={<Layout.Home />} />; }')

    expect(tree.routes.first.element_name).to eq("Home")
  end

  it "skips <Route> entries missing path or element" do
    tree = lower("function App() { return <Route element={<Home />} />; }")

    expect(tree.routes).to eq([])
  end

  it "returns an empty RouteTree when no <Route> elements are present" do
    tree = lower("function App() { return <div />; }")

    expect(tree.routes).to eq([])
  end
end
