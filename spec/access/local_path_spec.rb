# frozen_string_literal: true

require "spec_helper"
require "karst/access/local_path"

RSpec.describe Karst::Access::LocalPath do
  it "splits a local target into its path and raw query string" do
    parsed = described_class.parse("/documents/22?token=abc&x=1")

    expect(parsed.path).to eq("/documents/22")
    expect(parsed.query).to eq("token=abc&x=1")
  end

  it "reports no query when there is none" do
    expect(described_class.parse("/documents/22").query).to be_nil
  end

  it "refuses a target carrying a scheme and host" do
    expect { described_class.parse("http://evil.example/steal") }
      .to raise_error(Karst::Access::UnsafeTarget, /local application path/)
  end

  it "refuses a protocol-relative target" do
    expect { described_class.parse("//evil.example/steal") }.to raise_error(Karst::Access::UnsafeTarget)
  end

  it "refuses a relative target" do
    expect { described_class.parse("documents/22") }.to raise_error(Karst::Access::UnsafeTarget)
  end

  it "refuses a target Ruby cannot parse as a URI" do
    expect { described_class.parse("/documents/[22]") }
      .to raise_error(Karst::Access::UnsafeTarget, /valid local application path/)
  end

  it "exposes the query-stripped path for callers that never carry one" do
    expect(described_class.path("/documents/22?token=abc")).to eq("/documents/22")
  end
end
