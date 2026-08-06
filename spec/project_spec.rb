# frozen_string_literal: true

require "open3"
require "rbconfig"
require "karst"

RSpec.describe Karst do
  it "can be required" do
    _output, status = Open3.capture2e(
      RbConfig.ruby,
      "-I#{File.expand_path('../lib', __dir__)}",
      "-e",
      'require "karst"'
    )

    expect(status).to be_success
  end

  it "uses the same version as the gemspec" do
    gemspec = Gem::Specification.load(File.expand_path("../karst.gemspec", __dir__))

    expect(described_class::VERSION).to eq(gemspec.version.to_s)
  end

  it "does not expose or activate runtime behavior" do
    expect(described_class.constants(false)).to contain_exactly(:VERSION)
    expect(described_class.singleton_methods(false)).to be_empty
  end
end
