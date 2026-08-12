# frozen_string_literal: true

# On Rails 6.1, active_support/logger_thread_safe_level.rb references the
# bare ::Logger constant before active_support/logger.rb gets around to
# requiring "logger" itself -- a load-order bug in that Rails series, not a
# version conflict (it reproduces with Ruby's own bundled logger release,
# not just newer ones). A full Rails boot usually papers over it by sheer
# luck of some other gem having required "logger" first; requiring it here
# up front means `require "karst"` never depends on that luck.
require "logger"

require_relative "karst/version"
require_relative "karst/configuration"
require_relative "karst/identity"
require_relative "karst/access/sweep"
require_relative "karst/access/principal_source"
require_relative "karst/access/principal_sampler"
require_relative "karst/access/principal_selection"
require_relative "karst/access/search"
require_relative "karst/access/resource_evidence"
require_relative "karst/access/candidate_population"
require_relative "karst/access/population_discovery"
require_relative "karst/access/population_approvals"
require_relative "karst/access/approved_populations"
require_relative "karst/access/population_preview"
require_relative "karst/access/population_config_snippet"
require_relative "karst/access/principal_source_selection"
require_relative "karst/access/selected_principal_sources"

# Public entry point for Karst configuration.
module Karst
  @ownership_mutex = Mutex.new

  private_constant :Configuration

  class << self
    def configure
      yield config
    end

    def config
      @ownership_mutex.synchronize { @config ||= Configuration.new }
    end

    # The single switch that turns Karst's whole development surface off:
    # /karst, the page badge, `bin/rails karst:verify`, and the MCP
    # verify_access tool all refuse to run when this is false. Defaults to
    # development/test only, so an application that never configures Karst
    # at all still cannot expose it in production.
    def enabled?
      config.enabled
    end
  end
end

require_relative "karst/railtie" if defined?(Rails::Railtie)
