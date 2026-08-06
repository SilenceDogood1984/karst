# frozen_string_literal: true

RSpec.describe "Karst project" do
  it "has not introduced runtime instrumentation" do
    expect(Dir[File.expand_path("../lib/**/*.rb", __dir__)]).to be_empty
  end
end
