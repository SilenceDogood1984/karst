# frozen_string_literal: true

require "spec_helper"
require "karst/cli/principal_reference"

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::CLI::PrincipalReference do
  describe ".parse" do
    it "splits a MODEL:ID reference" do
      expect(described_class.parse("User:72")).to eq(described_class::Reference.new("User", "72"))
    end

    it "keeps everything after the first colon as the id" do
      expect(described_class.parse("User:abc:def")).to eq(described_class::Reference.new("User", "abc:def"))
    end

    it "refuses a reference with no colon" do
      expect { described_class.parse("User72") }.to raise_error(ArgumentError, /MODEL:ID/)
    end

    it "refuses a reference with an empty model or id" do
      expect { described_class.parse(":72") }.to raise_error(ArgumentError, /MODEL:ID/)
      expect { described_class.parse("User:") }.to raise_error(ArgumentError, /MODEL:ID/)
      expect { described_class.parse("") }.to raise_error(ArgumentError, /MODEL:ID/)
    end
  end

  describe ".resolve" do
    it "resolves exclusively through Identity.resolve, never a bespoke lookup" do
      principal = instance_double("Principal")
      allow(Karst::Identity).to receive(:resolve).with(model_name: "User", id: "72").and_return(principal)

      expect(described_class.resolve("User:72")).to equal(principal)
    end

    it "raises a clear ArgumentError, never nil, when Identity.resolve finds nothing" do
      allow(Karst::Identity).to receive(:resolve).with(model_name: "User", id: "999").and_return(nil)

      expect { described_class.resolve("User:999") }
        .to raise_error(ArgumentError, /--as User:999 did not resolve.*no User #999/)
    end

    it "propagates a configuration error from Identity.resolve rather than swallowing it" do
      allow(Karst::Identity).to receive(:resolve).and_raise(Karst::Identity::Unavailable, "no principal source")

      expect { described_class.resolve("User:72") }.to raise_error(Karst::Identity::Unavailable)
    end

    it "refuses a malformed reference before ever calling Identity.resolve" do
      allow(Karst::Identity).to receive(:resolve)

      expect { described_class.resolve("garbage") }.to raise_error(ArgumentError, /MODEL:ID/)
      expect(Karst::Identity).not_to have_received(:resolve)
    end
  end
end
# rubocop:enable Metrics/BlockLength
