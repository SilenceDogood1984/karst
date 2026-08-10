# frozen_string_literal: true

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.raise_errors_for_deprecations!
  config.order = :random
  Kernel.srand config.seed

  config.after do
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
