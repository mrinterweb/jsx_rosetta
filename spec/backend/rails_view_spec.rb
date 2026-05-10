# frozen_string_literal: true

RSpec.describe JsxRosetta::Backend::RailsView do
  subject(:backend) { described_class.new }

  def files_for(jsx_source)
    component = JsxRosetta.lower(jsx_source)
    backend.emit(component).to_h { |file| [file.path, file.contents] }
  end

  it "emits one .html.erb (no Ruby class, no sidecar dir) for a no-prop component" do
    files = files_for("function Home() { return <h1>Welcome</h1>; }")

    expect(files.keys).to eq(["home.html.erb"])
    expect(files["home.html.erb"]).to include("<h1>")
    expect(files["home.html.erb"]).to include("Welcome")
  end

  it "translates props to @instance_var references in the template" do
    files = files_for("function Show({ post }) { return <h1>{post.title}</h1>; }")

    expect(files.keys).to eq(["show.html.erb"])
    expect(files["show.html.erb"]).to include("@post.title")
  end

  it "still emits a Stimulus controller alongside when inline handlers exist" do
    files = files_for("function CopyButton() { return <button onClick={() => copy()}>x</button>; }")

    expect(files.keys).to contain_exactly(
      "copy_button.html.erb",
      "copy_button_controller.js"
    )
    expect(files["copy_button.html.erb"]).to include('data-controller="copy-button"')
  end
end
