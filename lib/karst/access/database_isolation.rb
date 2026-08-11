# frozen_string_literal: true

require "active_support/notifications"
require_relative "../value"

module Karst
  module Access
    # Runs application-authored discovery code in a rollback-only transaction
    # and observes the same mutating SQL evidence used by Access::Sweep.
    # This is same-connection database containment, not general side-effect
    # isolation: jobs, mail, network calls, files, Redis, and writes through
    # other connections remain outside this boundary.
    class DatabaseIsolation
      MUTATION = %r{\A\s*(?:/\*.*?\*/\s*)*(INSERT|UPDATE|DELETE)\b}im

      Result = Value.define(:value, :exception, :write_count, :database_rollback_attempted)

      def self.call(connection_class:, &block)
        new(connection_class, block).call
      end

      def self.mutation?(sql)
        sql.to_s.match?(MUTATION)
      end

      def initialize(connection_class, callable)
        @connection_class = connection_class
        @callable = callable
        @writes = 0
      end

      def call
        @connection_class.transaction(requires_new: true) do
          ActiveSupport::Notifications.subscribed(method(:observe), "sql.active_record") { capture }
          raise ActiveRecord::Rollback
        end

        result(rollback_attempted: true)
      rescue StandardError => e
        @exception ||= e
        result(rollback_attempted: false)
      end

      private

      def capture
        @value = @callable.call
      rescue StandardError => e
        @exception = e
      end

      def observe(_name, _start, _finish, _id, payload)
        @writes += 1 if self.class.mutation?(payload[:sql])
      end

      def result(rollback_attempted:)
        Result.new(value: @value, exception: @exception, write_count: @writes,
                   database_rollback_attempted: rollback_attempted)
      end
    end
  end
end
