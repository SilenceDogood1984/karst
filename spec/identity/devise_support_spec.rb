# frozen_string_literal: true

require "spec_helper"
require "karst"

# Devise itself is not a dependency of this gem or its test suite (Karst must
# never require Devise to load). Devise::Mapping's real public contract is
# just `#to` (the mapped class) and `#name` (the Warden scope symbol,
# populated by `devise_for` in config/routes.rb), so a minimal double with
# exactly that shape is enough to prove DeviseSupport reads it correctly --
# without coupling this suite to the real gem.
DeviseSupportSpecUser = Struct.new(:id)
DeviseSupportSpecAdmin = Struct.new(:id)
DeviseSupportSpecStaffMember = Struct.new(:id)
DeviseSupportSpecFakeMapping = Struct.new(:to, :name)

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Identity::DeviseSupport do
  after { hide_const("Devise") if defined?(Devise) }

  def stub_devise(mappings)
    stub_const("Devise", Module.new)
    allow(Devise).to receive(:mappings).and_return(mappings)
  end

  describe ".available?" do
    it "is false when Devise is not defined" do
      hide_const("Devise") if defined?(Devise)

      expect(described_class.available?).to be(false)
    end

    it "is true when Devise exposes .mappings" do
      stub_devise(user: DeviseSupportSpecFakeMapping.new(DeviseSupportSpecUser, :user))

      expect(described_class.available?).to be(true)
    end
  end

  describe ".mappings" do
    it "is empty when Devise is unavailable" do
      hide_const("Devise") if defined?(Devise)

      expect(described_class.mappings).to eq([])
    end

    it "reflects every Devise-registered model/scope pair" do
      stub_devise(
        user: DeviseSupportSpecFakeMapping.new(DeviseSupportSpecUser, :user),
        admin: DeviseSupportSpecFakeMapping.new(DeviseSupportSpecAdmin, :admin)
      )

      expect(described_class.mappings).to contain_exactly(
        Karst::Identity::DeviseSupport::Mapping.new(model: DeviseSupportSpecUser, scope: :user),
        Karst::Identity::DeviseSupport::Mapping.new(model: DeviseSupportSpecAdmin, scope: :admin)
      )
    end

    it "derives the scope from Devise's own mapping, not a hardcoded :user" do
      stub_devise(staff_member: DeviseSupportSpecFakeMapping.new(DeviseSupportSpecStaffMember, :staff_member))

      expect(described_class.mappings.first.scope).to eq(:staff_member)
    end
  end

  describe ".unambiguous_mapping" do
    it "is nil with zero Devise models" do
      stub_devise({})

      expect(described_class.unambiguous_mapping).to be_nil
    end

    it "is nil with more than one Devise model -- Karst never guesses" do
      stub_devise(
        user: DeviseSupportSpecFakeMapping.new(DeviseSupportSpecUser, :user),
        admin: DeviseSupportSpecFakeMapping.new(DeviseSupportSpecAdmin, :admin)
      )

      expect(described_class.unambiguous_mapping).to be_nil
    end

    it "is the single mapping with exactly one Devise model" do
      stub_devise(user: DeviseSupportSpecFakeMapping.new(DeviseSupportSpecUser, :user))

      expect(described_class.unambiguous_mapping).to have_attributes(model: DeviseSupportSpecUser, scope: :user)
    end
  end

  describe ".mapping_for" do
    it "finds the mapping for one specific model even when multiple models are registered" do
      stub_devise(
        user: DeviseSupportSpecFakeMapping.new(DeviseSupportSpecUser, :user),
        admin: DeviseSupportSpecFakeMapping.new(DeviseSupportSpecAdmin, :admin)
      )

      expect(described_class.mapping_for(DeviseSupportSpecAdmin)).to have_attributes(scope: :admin)
    end

    it "matches a subclass of a mapped model (e.g. single-table inheritance)" do
      stub_devise(user: DeviseSupportSpecFakeMapping.new(DeviseSupportSpecUser, :user))
      subclass = Class.new(DeviseSupportSpecUser)

      expect(described_class.mapping_for(subclass)).to have_attributes(scope: :user)
    end

    it "is nil for a model Devise does not map" do
      stub_devise(user: DeviseSupportSpecFakeMapping.new(DeviseSupportSpecUser, :user))

      expect(described_class.mapping_for(DeviseSupportSpecAdmin)).to be_nil
    end

    it "is nil for a non-Class argument rather than raising" do
      stub_devise(user: DeviseSupportSpecFakeMapping.new(DeviseSupportSpecUser, :user))

      expect(described_class.mapping_for(nil)).to be_nil
    end
  end
end
# rubocop:enable Metrics/BlockLength
