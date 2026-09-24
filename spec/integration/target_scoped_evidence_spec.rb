# frozen_string_literal: true

require "spec_helper"
require_relative "../support/test_application"
require "fileutils"
require "tmpdir"

# Target-scoped, phase-aware request evidence, against a real booted Rails
# application -- exactly like request_reproduction_spec.rb, and deliberately
# not against Arch.old or any stubbed session, because the bug this guards
# against is in how ActionDispatch::Integration::Session's own request/
# response pointers behave across two real requests on the same session.
#
# The bug: identity establishment can run a real request (a login, a
# clear_identity hook, anything through the same session) immediately before
# the target request. ActionDispatch::Integration::Session#process only
# reassigns @request/@response *after* Rack::Test's app.call returns without
# raising, so a target that raises before producing a response leaves those
# two objects holding the *previous* request's status, content type, and
# location. Karst must never report that inherited fact as if it observed it
# for the target.
#
# Real files under a real temp directory, deliberately not
# ActionView::FixtureResolver: that resolver hardcodes its own #path to "" (see
# ActionView::FixtureResolver#initialize, which calls super("")), and on Rails
# <= 7.0 assigning it as a controller's view_paths registers that "" path,
# permanently, into ActionView::ViewPaths.all_view_paths -- a process-wide
# registry every ActionView::CacheExpiry check (run before *every* request
# dispatched through a full Rails middleware stack, in *any* spec in the same
# process, for the rest of that process) reads via
# ActionView::CacheExpiry#dirs_to_watch. That "" then becomes a watched
# directory, and ActiveSupport::FileUpdateChecker joins it into a glob with
# File.join("", "**", "*"), which is "/**/*" -- an unbounded recursive scan of
# the entire filesystem root on every single subsequent full-stack request.
# (Rails >= 7.1 replaced that registry with ActionView::PathRegistry, which
# only auto-registers String/Pathname viewpaths into its watched-resolver set,
# so a resolver *object* passed directly, like a FixtureResolver, is never
# swept in there -- masking this exact mistake on newer Rails while still
# making it on 6.1/7.0.) A real, bounded temp directory can never produce that
# pattern.
#
# Guarded by `defined?`, not just required-once by convention: RSpec loads a
# file explicitly named on its command line (or matched by its own glob) with
# Kernel#load, not #require, so it does not consult -- or populate --
# $LOADED_FEATURES. A second file that also `require_relative`s this one
# (spec/integration/view_paths_process_isolation_spec.rb does, deliberately,
# so its regression does not depend on load order) would otherwise re-run
# this whole side-effecting block: a second Dir.mktmpdir, a second `at_exit`
# racing the first to remove *whichever* directory
# KARST_EVIDENCE_VIEW_PATH -- a constant, re-assigned by the second run --
# happens to name by the time either block fires, and duplicate routes.
unless defined?(KarstEvidenceFixtureController)
  KARST_EVIDENCE_VIEW_PATH = Dir.mktmpdir("karst-evidence-views")
  at_exit { FileUtils.remove_entry(KARST_EVIDENCE_VIEW_PATH) }

  {
    "karst_evidence_fixture/edit.html.erb" => "<p>edit view</p>",
    "karst_evidence_fixture/broken.html.erb" => "<% raise 'template boom' %>",
    "layouts/application.html.erb" => "<html><body><%= yield %></body></html>"
  }.each do |relative_path, content|
    full_path = File.join(KARST_EVIDENCE_VIEW_PATH, relative_path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, content)
  end

  # A real login-shaped request -- returns 200/text/html, exactly the
  # reported bug's request A -- plus one route per behavioral case (Part 7).
  class KarstEvidenceFixtureController < ActionController::Base
    self.view_paths = KARST_EVIDENCE_VIEW_PATH
    layout "application"

    before_action :halt_gate!, only: :gated

    def login
      render plain: "ok", content_type: "text/html"
    end

    def boom
      raise "target exploded"
    end

    def edit
      render "edit"
    end

    def broken
      render "broken"
    end

    def show_redirect
      redirect_to "/karst_evidence/edit"
    end

    def gated
      render plain: "unreachable"
    end

    private

    def halt_gate!
      head :forbidden
    end
  end

  KarstTestApplication.routes.send(:eval_block, proc {
    get "/karst_evidence/login", to: "karst_evidence_fixture#login"
    get "/karst_evidence/boom", to: "karst_evidence_fixture#boom"
    get "/karst_evidence/edit", to: "karst_evidence_fixture#edit"
    get "/karst_evidence/broken", to: "karst_evidence_fixture#broken"
    get "/karst_evidence/redirect", to: "karst_evidence_fixture#show_redirect"
    get "/karst_evidence/gated", to: "karst_evidence_fixture#gated"
  })
end

# rubocop:disable Metrics/BlockLength
RSpec.describe "target-scoped, phase-aware request evidence" do
  before do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
  end

  def exercise(path:, **overrides)
    Karst::Reproduction::Exercise.new(path: path, application: KarstTestApplication, **overrides).call
  end

  # A completed request (the login stand-in) immediately before the target,
  # on the exact same ActionDispatch::Integration::Session -- via
  # config.clear_identity, the seam Access::IdentityProbe runs for an
  # anonymous probe (Exercise's default) before ever touching the target.
  def exercise_after_prior_request(path:, **overrides)
    Karst.config.clear_identity = ->(session) { session.get("/karst_evidence/login") }
    exercise(path: path, **overrides)
  end

  describe "Part 1/7A -- a prior request completed, then the target raises" do
    it "never lets the target inherit the prior request's status, content type, or location" do
      observation = exercise_after_prior_request(path: "/karst_evidence/boom")

      expect(observation.controller).to eq("KarstEvidenceFixtureController")
      expect(observation.action).to eq("boom")
      expect(observation.controller_completed).to be(false)
      expect(observation.exception_class).to eq("RuntimeError")
      expect(observation.exception_phase).to eq("controller")

      # The prior request's own facts -- exactly what a stale
      # session.response/session.request would otherwise leak.
      expect(observation.status).not_to eq(200)
      expect(observation.status).to be_nil
      expect(observation.response_content_type).to be_nil
      expect(observation.redirect).to be_nil

      expect(observation.unobserved).to include("status", "response_content_type")
      expect(observation.rendered).to eq([])
    end
  end

  describe "Part 7B -- a normal successful request" do
    it "observes status, controller completion, no exception, and real render evidence" do
      observation = exercise(path: "/karst_evidence/edit")

      expect(observation.status).to eq(200)
      expect(observation.controller_completed).to be(true)
      expect(observation.exception_class).to be_nil
      expect(observation.exception_phase).to be_nil
      expect(observation.rendered).to eq(
        [{ virtual_path: "karst_evidence_fixture/edit", completed: true },
         { virtual_path: "layouts/application", completed: true }]
      )
    end
  end

  describe "Part 7C -- a controller/action exception, with no prior request" do
    it "reports dispatch, non-completion, and a controller-phase exception, with no fabricated response" do
      observation = exercise(path: "/karst_evidence/boom")

      expect(observation.controller).to eq("KarstEvidenceFixtureController")
      expect(observation.action).to eq("boom")
      expect(observation.controller_completed).to be(false)
      expect(observation.exception_class).to eq("RuntimeError")
      expect(observation.exception_phase).to eq("controller")
      expect(observation.status).to be_nil
      expect(observation.response_content_type).to be_nil
      expect(observation.unobserved).to include("status", "response_content_type")
    end
  end

  describe "Part 7D -- a rendering exception" do
    it "attributes the exception to render, with structural template evidence and no stale response" do
      observation = exercise(path: "/karst_evidence/broken")

      expect(observation.controller).to eq("KarstEvidenceFixtureController")
      expect(observation.action).to eq("broken")
      expect(observation.exception_phase).to eq("render")
      expect(observation.exception_class).to eq("ActionView::Template::Error")
      expect(observation.rendered).to eq([{ virtual_path: "karst_evidence_fixture/broken", completed: false }])
      expect(observation.status).to be_nil
      expect(observation.response_content_type).to be_nil
    end
  end

  describe "Part 7E -- a redirect" do
    it "reports the target's own redirect status/location and no false render claim" do
      observation = exercise(path: "/karst_evidence/redirect")

      expect(observation.status).to eq(302)
      expect(observation.redirect).to eq("http://karst-probe.example/karst_evidence/edit")
      expect(observation.controller_completed).to be(true)
      expect(observation.exception_class).to be_nil
      expect(observation.rendered).to eq([])
    end
  end

  describe "Part 7F -- a halted callback" do
    it "keeps halted_callback distinct from controller_completed and from an exception" do
      observation = exercise(path: "/karst_evidence/gated")

      expect(observation.halted_callback).to eq("halt_gate!")
      expect(observation.controller_completed).to be(true)
      expect(observation.exception_class).to be_nil
      expect(observation.status).to eq(403)
    end
  end

  describe "Part 6 -- unobserved dispatch never claims controller_completed" do
    it "reports controller_completed as unobserved when nothing ever dispatched" do
      observation = exercise(path: "/karst_evidence/does-not-exist")

      expect(observation.controller).to be_nil
      expect(observation.controller_completed).to be_nil
      expect(observation.unobserved).to include("controller", "action", "controller_completed")
    end
  end
end
# rubocop:enable Metrics/BlockLength
