# frozen_string_literal: true

module Karst
  # Owns the lifecycle of Karst's inert Active Support notification callback.
  class Subscription
    EVENT_NAME = "sql.active_record"

    def initialize(callback: nil)
      @callback = callback || proc { |_name, _start, _finish, _id, _payload| }
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

    def receive(*notification)
      @callback.call(*notification)
    rescue StandardError
      nil
    end
  end
end
