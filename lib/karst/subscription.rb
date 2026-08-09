# frozen_string_literal: true

# On Rails 6.1, active_support/logger_thread_safe_level.rb references the
# bare ::Logger constant before active_support/logger.rb gets around to
# requiring "logger" itself -- a load-order bug in that Rails series, not a
# version conflict (it reproduces with Ruby's own bundled logger release,
# not just newer ones). A full Rails boot usually papers over it by sheer
# luck of some other gem having required "logger" first; requiring it here
# up front means `require "karst"` never depends on that luck.
require "logger"
require "active_support"
require "active_support/notifications"

module Karst
  # Owns the lifecycle of Karst's Active Support notification callback.
  class Subscription
    EVENT_NAME = "sql.active_record"

    def initialize(receiver:)
      @receiver = receiver
      @notification_callback = method(:receive)
      @handle = nil
      @mutex = Mutex.new
    end

    def subscribe!
      @mutex.synchronize do
        return if @handle

        @handle = ActiveSupport::Notifications.monotonic_subscribe(EVENT_NAME, &@notification_callback)
      end
    end

    def unsubscribe!
      @mutex.synchronize do
        return unless @handle

        ActiveSupport::Notifications.unsubscribe(@handle)
        @handle = nil
      end
    end

    def subscribed?
      @mutex.synchronize { !@handle.nil? }
    end

    private

    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
    def receive(_notification_name, start, finish, _id, payload)
      return unless payload.respond_to?(:[]) && payload[:sql].is_a?(String)

      event = Sql::Event.new(
        name: payload[:name].is_a?(String) ? payload[:name].dup.freeze : nil,
        sql: payload[:sql].dup.freeze,
        cached: payload[:cached] ? true : false,
        duration_ms: (Float(finish) - Float(start)) * 1000.0,
        monotonic_started_at: Float(start)
      )
      @receiver.__send__(:call, event)
    rescue StandardError => e
      reporter = ActiveSupport.error_reporter if ActiveSupport.respond_to?(:error_reporter)
      reporter&.report(e, handled: true, context: { source: "karst" })
      nil
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
  end
end
