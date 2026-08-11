# frozen_string_literal: true

require_relative "karst/version"
require_relative "karst/configuration"
require_relative "karst/identity"
require_relative "karst/access/sweep"
require_relative "karst/access/principal_dimension"
require_relative "karst/access/principal_source"
require_relative "karst/access/principal_sampler"
require_relative "karst/access/principal_selection"
require_relative "karst/access/resource_evidence"
require_relative "karst/access/artifact_source"
require_relative "karst/access/scenario"
require_relative "karst/access/scenario_sweep"
require_relative "karst/access/candidate_population"
require_relative "karst/access/population_discovery"
require_relative "karst/access/population_preview"
require_relative "karst/access/population_suggestion"
require_relative "karst/access/population_config_snippet"
require_relative "karst/buffer"
require_relative "karst/sql/event"
require_relative "karst/sql/canonicalizer"
require_relative "karst/sql/shape"
require_relative "karst/sql/window"
require_relative "karst/subscription"

# Public entry point for Karst configuration and subscription ownership.
module Karst
  @ownership_mutex = Mutex.new

  private_constant :Configuration, :Buffer, :Subscription
  Sql.private_constant :Canonicalizer

  class << self
    def configure
      yield config
    end

    def config
      @ownership_mutex.synchronize { @config ||= Configuration.new }
    end

    def enabled?
      config.enabled
    end

    def buffer
      capacity = config.buffer_size
      @ownership_mutex.synchronize { @buffer ||= Buffer.new(capacity: capacity) }
    end

    # One immutable snapshot of currently retained SQL evidence: safely canonicalized
    # Events grouped into Sql::Shape, plus the Events whose SQL declined canonicalization.
    def window
      active_buffer = buffer
      events = active_buffer.to_a
      shapes, declined = Sql::Shape.send(:group, events)

      Sql::Window.new(
        shapes: shapes.sort_by { |shape| [-shape.count, -shape.duration_ms_total, shape.fingerprint] }.freeze,
        declined: declined,
        event_count: events.size,
        capacity: active_buffer.capacity,
        saturated: events.size == active_buffer.capacity
      )
    end

    def subscribe!
      subscription.subscribe! if enabled?
    end

    def unsubscribe!
      existing_subscription = @ownership_mutex.synchronize { @subscription }
      existing_subscription&.unsubscribe!
    end

    def subscribed?
      existing_subscription = @ownership_mutex.synchronize { @subscription }
      existing_subscription ? existing_subscription.subscribed? : false
    end

    private

    def subscription
      receiver = buffer
      @ownership_mutex.synchronize { @subscription ||= Subscription.new(receiver: receiver) }
    end
  end
end

require_relative "karst/railtie" if defined?(Rails::Railtie)
