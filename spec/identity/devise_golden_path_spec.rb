# frozen_string_literal: true

require "spec_helper"
require "logger"
require "active_record"
require "karst"

# A dedicated, isolated Active Record connection -- deliberately not
# ActiveRecord::Base itself -- so this file's schema/fixtures can never
# collide with any other spec file's global AR::Base connection state,
# regardless of randomized spec order. Mirrors
# spec/access/principal_sampler_spec.rb's own fixture pattern.
class DeviseGoldenPathFixtureRecord < ActiveRecord::Base
  self.abstract_class = true
  establish_connection(adapter: "sqlite3", database: ":memory:")
end

class DeviseGoldenPathUser < DeviseGoldenPathFixtureRecord
  self.table_name = "devise_golden_path_users"
end

class DeviseGoldenPathAdmin < DeviseGoldenPathFixtureRecord
  self.table_name = "devise_golden_path_admins"
end

class DeviseGoldenPathStaffMember < DeviseGoldenPathFixtureRecord
  self.table_name = "devise_golden_path_staff_members"
end

[DeviseGoldenPathUser, DeviseGoldenPathAdmin, DeviseGoldenPathStaffMember].each do |klass|
  klass.connection.create_table(klass.table_name, force: true) { |t| t.boolean :active, default: true }
end

# Devise itself is not a dependency of this suite (see
# spec/identity/devise_support_spec.rb) -- a struct with Devise::Mapping's
# real public shape (#to, #name) is enough to prove Karst::Identity reads it
# correctly end to end.
DeviseGoldenPathMapping = Struct.new(:to, :name)

# A minimal, stateful stand-in for a real Warden proxy -- real enough to
# prove scope-correct set_user/logout and cross-principal cleanup, without
# requiring a full Warden::Manager Rack cycle (see
# spec/integration/warden_browser_identity_spec.rb for that).
class DeviseGoldenPathProxy
  def initialize
    @users = {}
  end

  def set_user(principal, scope: :default)
    @users[scope] = principal
  end

  def logout(scope = nil)
    scope ? @users.delete(scope) : @users.clear
  end

  def user(scope)
    @users[scope]
  end
end

# rubocop:disable Metrics/BlockLength
RSpec.describe "Karst::Identity Devise/Warden golden path" do
  def stub_devise(mappings)
    stub_const("Devise", Module.new)
    allow(Devise).to receive(:mappings).and_return(mappings)
  end

  def stub_warden
    stub_const("Warden::Manager", Class.new)
  end

  def session_for(proxy)
    { "warden" => proxy }
  end

  describe "exactly one Devise model" do
    before do
      stub_devise(user: DeviseGoldenPathMapping.new(DeviseGoldenPathUser, :user))
      stub_warden
    end

    it "exposes that model as the effective principal source without materializing it" do
      source = Karst::Identity.principals

      expect(source).to be_a(ActiveRecord::Relation)
      expect(source.klass).to eq(DeviseGoldenPathUser)
    end

    it "uses Warden automatically for probe identity with the correct Devise scope" do
      user = DeviseGoldenPathUser.create!
      proxy = DeviseGoldenPathProxy.new
      session = session_for(proxy)

      Karst::Identity.with(session, user) { expect(proxy.user(:user)).to eq(user) }

      expect(proxy.user(:user)).to be_nil
    end

    it "uses Warden automatically for browser identity with the correct Devise scope" do
      user = DeviseGoldenPathUser.create!
      proxy = DeviseGoldenPathProxy.new
      request = Struct.new(:env).new(session_for(proxy))

      expect(Karst::Identity.browser_supported?).to be(true)

      Karst::Identity.assume_browser(request, user)
      expect(proxy.user(:user)).to eq(user)

      Karst::Identity.clear_browser(request)
      expect(proxy.user(:user)).to be_nil
    end

    it "reports ready_automatic with no configuration at all" do
      expect(Karst::Identity.setup_state).to have_attributes(status: :ready_automatic, message: nil)
    end

    it "does not leak identity between sequentially probed principals" do
      first = DeviseGoldenPathUser.create!
      second = DeviseGoldenPathUser.create!
      proxy = DeviseGoldenPathProxy.new
      session = session_for(proxy)

      Karst::Identity.with(session, first) { expect(proxy.user(:user)).to eq(first) }
      expect(proxy.user(:user)).to be_nil

      Karst::Identity.with(session, second) { expect(proxy.user(:user)).to eq(second) }
      expect(proxy.user(:user)).to be_nil
    end
  end

  describe "explicit configuration overriding an available Devise model" do
    before do
      stub_devise(user: DeviseGoldenPathMapping.new(DeviseGoldenPathUser, :user))
      stub_warden
    end

    it "uses config.principals instead of the inferred Devise model" do
      custom_source = [DeviseGoldenPathUser.create!]
      Karst.config.principals = -> { custom_source }

      expect(Karst::Identity.principals).to equal(custom_source)
    end

    it "uses explicit assume_identity/clear_identity instead of the Warden adapter" do
      calls = []
      Karst.config.assume_identity = ->(_session, principal) { calls << [:assume, principal] }
      Karst.config.clear_identity = ->(_session) { calls << [:clear] }
      user = DeviseGoldenPathUser.create!
      proxy = DeviseGoldenPathProxy.new

      Karst::Identity.with(session_for(proxy), user) { nil }

      expect(proxy.user(:user)).to be_nil, "the Warden proxy must never be touched when explicit hooks are configured"
      expect(calls).to eq([[:assume, user], [:clear]])
    end
  end

  describe "more than one Devise model" do
    before do
      stub_devise(
        user: DeviseGoldenPathMapping.new(DeviseGoldenPathUser, :user),
        admin: DeviseGoldenPathMapping.new(DeviseGoldenPathAdmin, :admin)
      )
      stub_warden
    end

    it "does not automatically choose a principal source" do
      expect { Karst::Identity.principals }.to raise_error(Karst::Identity::Unavailable)
    end

    it "reports :ambiguous naming every detected model" do
      state = Karst::Identity.setup_state

      expect(state.status).to eq(:ambiguous)
      expect(state.message).to include("DeviseGoldenPathAdmin", "DeviseGoldenPathUser")
    end

    it "exposes no automatic browser identity while ambiguous" do
      expect(Karst::Identity.browser_supported?).to be(false)
    end

    it "still infers Warden scope automatically once config.principals selects one model" do
      Karst.config.principals = -> { DeviseGoldenPathAdmin.all }
      admin = DeviseGoldenPathAdmin.create!
      proxy = DeviseGoldenPathProxy.new

      Karst::Identity.with(session_for(proxy), admin) { expect(proxy.user(:admin)).to eq(admin) }

      expect(proxy.user(:admin)).to be_nil
      expect(Karst::Identity.setup_state.status).to eq(:ready_mixed)
    end

    # Karst never edits an initializer to resolve this ambiguity: a
    # developer instead selects locally at /karst (see
    # Karst::Access::PrincipalSourceSelection), and everything downstream --
    # principal_sources, probe identity, browser identity, CLI, MCP -- picks
    # it up with no further wiring.
    describe "resolved through a locally selected principal source" do
      before { allow(Karst::Access::ApprovedPopulations).to receive(:local_environment?).and_return(true) }

      after { Karst::Access::PrincipalSourceSelection.replace([]) }

      it "selects only the User model" do
        Karst::Access::PrincipalSourceSelection.replace(["DeviseGoldenPathUser"])

        sources = Karst::Identity.principal_sources

        expect(sources.keys).to eq([:user])
        expect(sources[:user].record_klass).to eq(DeviseGoldenPathUser)
        expect(Karst::Identity.setup_state.status).to eq(:ready_automatic)
      end

      it "selects only the Admin model" do
        Karst::Access::PrincipalSourceSelection.replace(["DeviseGoldenPathAdmin"])

        sources = Karst::Identity.principal_sources

        expect(sources.keys).to eq([:admin])
        expect(sources[:admin].record_klass).to eq(DeviseGoldenPathAdmin)
      end

      it "selects both models as independently queryable sources, never one combined source" do
        Karst::Access::PrincipalSourceSelection.replace(%w[DeviseGoldenPathUser DeviseGoldenPathAdmin])

        sources = Karst::Identity.principal_sources

        expect(sources.keys).to contain_exactly(:user, :admin)
        expect(sources[:user].record_klass).to eq(DeviseGoldenPathUser)
        expect(sources[:admin].record_klass).to eq(DeviseGoldenPathAdmin)
        expect(Karst::Identity.browser_supported?).to be(true)
        expect(Karst::Identity.setup_state.status).to eq(:ready_automatic)
      end

      it "assumes and clears each selected model's own Devise/Warden scope for probe identity" do
        Karst::Access::PrincipalSourceSelection.replace(%w[DeviseGoldenPathUser DeviseGoldenPathAdmin])
        user = DeviseGoldenPathUser.create!
        admin = DeviseGoldenPathAdmin.create!
        proxy = DeviseGoldenPathProxy.new

        Karst::Identity.with(session_for(proxy), user) { expect(proxy.user(:user)).to eq(user) }
        expect(proxy.user(:user)).to be_nil
        expect(proxy.user(:admin)).to be_nil

        Karst::Identity.with(session_for(proxy), admin) { expect(proxy.user(:admin)).to eq(admin) }
        expect(proxy.user(:admin)).to be_nil
        expect(proxy.user(:user)).to be_nil
      end

      it "assumes each selected model's own scope for browser identity and retains it to clear correctly" do
        Karst::Access::PrincipalSourceSelection.replace(%w[DeviseGoldenPathUser DeviseGoldenPathAdmin])
        admin = DeviseGoldenPathAdmin.create!
        proxy = DeviseGoldenPathProxy.new
        request = Struct.new(:env).new(session_for(proxy))

        scope = Karst::Identity.assume_browser(request, admin)

        expect(scope).to eq(:admin)
        expect(proxy.user(:admin)).to eq(admin)

        # Stopping must clear exactly the scope that was assumed -- not
        # guess at "the" effective source, which no longer exists once more
        # than one is selected.
        Karst::Identity.clear_browser(request, scope: scope)
        expect(proxy.user(:admin)).to be_nil
      end

      it "refuses to guess a scope for a bare clear with no stored scope and several selected sources" do
        Karst::Access::PrincipalSourceSelection.replace(%w[DeviseGoldenPathUser DeviseGoldenPathAdmin])
        proxy = DeviseGoldenPathProxy.new
        request = Struct.new(:env).new(session_for(proxy))

        expect { Karst::Identity.clear_browser(request) }.to raise_error(Karst::Identity::Unavailable)
      end

      it "reverts to ambiguous once every selected mapping is stale, never guessing" do
        Karst::Access::PrincipalSourceSelection.replace(["DeviseGoldenPathStaffMember"])

        expect { Karst::Identity.principals }.to raise_error(Karst::Identity::Unavailable)
        expect(Karst::Identity.setup_state.status).to eq(:ambiguous)
      end

      it "ignores a hand-written entry naming a model Devise never mapped, never constantizing it" do
        Karst::Access::PrincipalSourceSelection.replace(["Object"])

        expect(Karst::Identity.setup_state.status).to eq(:ambiguous)
      end

      it "keeps an explicit config.principals ahead of a saved local selection" do
        Karst::Access::PrincipalSourceSelection.replace(%w[DeviseGoldenPathUser DeviseGoldenPathAdmin])
        Karst.config.principals = -> { DeviseGoldenPathUser.all }

        expect(Karst::Identity.principal_sources.keys).to eq([:default])
      ensure
        Karst.config.principals = nil
      end

      it "keeps an explicit config.principal_sources ahead of a saved local selection" do
        Karst::Access::PrincipalSourceSelection.replace(%w[DeviseGoldenPathUser DeviseGoldenPathAdmin])
        Karst.config.principal_sources = { explicit: -> { DeviseGoldenPathUser.all } }

        expect(Karst::Identity.principal_sources.keys).to eq([:explicit])
      ensure
        Karst.config.principal_sources = nil
      end
    end
  end

  describe "a nonstandard Devise model name" do
    it "derives the Warden scope from Devise's mapping, not a hardcoded :user" do
      stub_devise(staff_member: DeviseGoldenPathMapping.new(DeviseGoldenPathStaffMember, :staff_member))
      stub_warden
      staff = DeviseGoldenPathStaffMember.create!
      proxy = DeviseGoldenPathProxy.new

      Karst::Identity.with(session_for(proxy), staff) { expect(proxy.user(:staff_member)).to eq(staff) }
    end
  end

  describe "no Devise metadata available" do
    before { hide_const("Devise") if defined?(Devise) }

    it "does not guess a principal model" do
      expect { Karst::Identity.principals }.to raise_error(Karst::Identity::Unavailable, /no principal source/)
    end

    it "still honors explicit configuration" do
      custom_source = [DeviseGoldenPathUser.create!]
      Karst.config.principals = -> { custom_source }

      expect(Karst::Identity.principals).to equal(custom_source)
    end
  end

  describe "Warden unavailable despite Devise metadata" do
    before do
      stub_devise(user: DeviseGoldenPathMapping.new(DeviseGoldenPathUser, :user))
      hide_const("Warden") if defined?(Warden)
    end

    it "reports automatic identity as unavailable rather than partially working" do
      user = DeviseGoldenPathUser.create!

      expect { Karst::Identity.with({}, user) { nil } }.to raise_error(Karst::Identity::Unavailable)
      expect(Karst::Identity.browser_supported?).to be(false)
      expect(Karst::Identity.setup_state.status).to eq(:unavailable)
    end
  end

  describe "source scoping remains enforced through an inferred Devise model" do
    it "cannot resolve an id outside the effective source's own scope" do
      stub_devise(user: DeviseGoldenPathMapping.new(DeviseGoldenPathUser, :user))
      stub_warden
      active = DeviseGoldenPathUser.create!(active: true)
      inactive = DeviseGoldenPathUser.create!(active: false)
      Karst.config.principals = -> { DeviseGoldenPathUser.where(active: true) }

      resolved_active = Karst::Identity.resolve(model_name: "DeviseGoldenPathUser", id: active.id)
      resolved_inactive = Karst::Identity.resolve(model_name: "DeviseGoldenPathUser", id: inactive.id)

      expect(resolved_active).to eq(active)
      expect(resolved_inactive).to be_nil
    end
  end
end
# rubocop:enable Metrics/BlockLength
