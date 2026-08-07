# frozen_string_literal: true

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
      @receiver.call(event)
    rescue StandardError => e
      reporter = ActiveSupport.error_reporter if ActiveSupport.respond_to?(:error_reporter)
      reporter&.report(e, handled: true, context: { source: "karst" })
      nil
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
  end
end
