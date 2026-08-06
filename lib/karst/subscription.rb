# frozen_string_literal: true

module Karst
  # Owns the lifecycle of Karst's Active Support notification callback.
  class Subscription
    EVENT_NAME = "sql.active_record"

    def initialize(receiver: nil)
      @receiver = receiver || proc { |_event| }
      @notification_callback = method(:receive)
      @handle = nil
    end

    def subscribe!
      return if subscribed?

      require "active_support"
      require "active_support/notifications"
      @handle = ActiveSupport::Notifications.monotonic_subscribe(EVENT_NAME, &@notification_callback)
    end

    def unsubscribe!
      return unless subscribed?

      ActiveSupport::Notifications.unsubscribe(@handle)
      @handle = nil
    end

    def subscribed?
      !@handle.nil?
    end

    private

    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    def receive(_notification_name, start, finish, _id, payload)
      return unless payload.respond_to?(:[]) && payload[:sql].is_a?(String)

      event = Sql::Event.new(
        name: payload[:name].is_a?(String) ? payload[:name].dup.freeze : nil,
        sql: payload[:sql].dup.freeze,
        cached: payload[:cached] ? true : false,
        duration_ms: (Float(finish) - Float(start)) * 1000.0,
        started_at: Float(start)
      )
      @receiver.call(event)
    rescue StandardError
      nil
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength
  end
end
