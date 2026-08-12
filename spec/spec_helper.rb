# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# rubocop:disable Metrics/BlockLength
RSpec.configure do |config|
  config.disable_monkey_patching!
  config.raise_errors_for_deprecations!
  config.order = :random
  Kernel.srand config.seed

  # Karst::Access::PopulationApprovals.path defaults to
  # "#{Rails.root}/tmp/karst/approved_populations.json", and several specs
  # (spec/support/test_application.rb's KarstTestApplication among them) boot
  # a real Rails::Application whose root resolves to this gem's own
  # repository -- there is no config.ru or other app-root marker to stop
  # Rails' own root-finding walk. Left unstubbed, that would make an
  # ordinary, unrelated spec silently depend on whatever a developer happens
  # to have approved by hand while dogfooding Karst against a real app in
  # this checkout, and would let one example's approval write leak into the
  # next. Every example gets its own process-unique, never-preexisting path
  # instead; specs that specifically exercise PopulationApprovals override
  # this in their own (later-registered, and therefore higher-precedence)
  # before block exactly as any other spec-local stub would.
  config.before do
    next unless defined?(Karst::Access::PopulationApprovals)

    isolated_path = File.join(Dir.tmpdir, "karst-rspec-#{Process.pid}", "approved_populations.json")
    allow(Karst::Access::PopulationApprovals).to receive(:path).and_return(isolated_path)
  end

  # Same isolation, same reason, for Karst::Access::PrincipalSourceSelection
  # (tmp/karst/principal_source_selection.json): several specs boot a real
  # Rails::Application whose root resolves to this checkout, and Configuration
  # #principal_sources now reads this file too whenever several Devise models
  # are detected and nothing explicit is configured.
  config.before do
    next unless defined?(Karst::Access::PrincipalSourceSelection)

    isolated_path = File.join(Dir.tmpdir, "karst-rspec-#{Process.pid}", "principal_source_selection.json")
    allow(Karst::Access::PrincipalSourceSelection).to receive(:path).and_return(isolated_path)
  end

  config.after do
    if defined?(Karst::Access::PopulationApprovals)
      isolated_path = File.join(Dir.tmpdir, "karst-rspec-#{Process.pid}", "approved_populations.json")
      FileUtils.rm_f(isolated_path)
    end

    if defined?(Karst::Access::PrincipalSourceSelection)
      isolated_path = File.join(Dir.tmpdir, "karst-rspec-#{Process.pid}", "principal_source_selection.json")
      FileUtils.rm_f(isolated_path)
    end

    # Bundler's `gemspec` directive evaluates karst.gemspec (which requires
    # lib/karst/version.rb) before any spec file loads, so `Karst` may exist
    # as a bare VERSION-only module even in a run where no spec file has
    # required the full library -- `defined?(Karst)` alone can't tell those
    # apart.
    next unless defined?(Karst) && Karst.respond_to?(:unsubscribe!)

    Karst.unsubscribe!
    configuration = Karst.const_get(:Configuration, false).new
    configuration.enabled = false
    Karst.instance_variable_set(:@config, configuration)
    %i[@buffer @subscription].each do |variable|
      Karst.remove_instance_variable(variable) if Karst.instance_variable_defined?(variable)
    end
  end
end
# rubocop:enable Metrics/BlockLength
