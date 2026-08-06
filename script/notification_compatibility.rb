#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "logger"

gem "activesupport", ENV.fetch("AS_VERSION") if ENV["AS_VERSION"]
require "active_support"
require "active_support/notifications"

EVENT = "sql.active_record"

# Runs behavioral checks against the activated Active Support version and emits JSON.
class CompatibilityCheck
  def initialize
    @checks = {}
  end

  def run # rubocop:disable Metrics/MethodLength
    check_monotonic_delivery
    check_duplicate_subscriptions
    check_unsubscribe
    check_callback_exception

    report = {
      ruby: RUBY_VERSION,
      active_support: ActiveSupport.version.to_s,
      active_record_loaded: !defined?(ActiveRecord).nil?,
      event: EVENT,
      checks: @checks,
      passed: @checks.values.all? { |result| result.fetch(:pass) }
    }
    puts JSON.pretty_generate(report)
    exit(1) unless report.fetch(:passed)
  end

  private

  def record(name, pass:, **observations)
    @checks[name] = observations.merge(pass: pass)
  end

  def instrument(payload = {})
    ActiveSupport::Notifications.instrument(EVENT, payload) { :instrumented }
  end

  def check_monotonic_delivery # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    calls = []
    available = ActiveSupport::Notifications.respond_to?(:monotonic_subscribe)
    handle = (ActiveSupport::Notifications.monotonic_subscribe(EVENT) { |*arguments| calls << arguments } if available)
    instrument(query: "SELECT 1") if handle
    ActiveSupport::Notifications.unsubscribe(handle) if handle

    arguments = calls.first || []
    start, finish = arguments.values_at(1, 2)
    record(
      :monotonic_delivery,
      pass: available && calls.length == 1 && arguments.length == 5 &&
        start.is_a?(Numeric) && finish.is_a?(Numeric) && finish >= start,
      available: available,
      argument_count: arguments.length,
      argument_classes: arguments.map { |argument| argument.class.name },
      name: arguments[0],
      start: start,
      finish: finish,
      finish_not_before_start: start && finish ? finish >= start : nil,
      id_class: arguments[3]&.class&.name,
      payload: arguments[4]
    )
  end

  def check_duplicate_subscriptions
    calls = 0
    callback = proc { calls += 1 }
    handles = 2.times.map { ActiveSupport::Notifications.monotonic_subscribe(EVENT, &callback) }
    instrument
    handles.each { |handle| ActiveSupport::Notifications.unsubscribe(handle) }
    record(:duplicate_subscriptions, pass: calls == 2, callback_count: calls)
  end

  def check_unsubscribe # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    calls = 0
    handle = ActiveSupport::Notifications.monotonic_subscribe(EVENT) { calls += 1 }
    instrument
    first_result = capture { ActiveSupport::Notifications.unsubscribe(handle) }
    instrument
    second_result = capture { ActiveSupport::Notifications.unsubscribe(handle) }
    instrument
    record(
      :unsubscribe,
      pass: calls == 1 && first_result[:exception].nil? && second_result[:exception].nil?,
      callback_count: calls,
      first_return_class: first_result[:value_class],
      first_return_nil: first_result[:value_nil],
      first_exception: first_result[:exception],
      second_return_class: second_result[:value_class],
      second_return_nil: second_result[:value_nil],
      second_exception: second_result[:exception]
    )
  end

  def check_callback_exception # rubocop:disable Metrics/MethodLength
    calls = 0
    raised_handle = ActiveSupport::Notifications.monotonic_subscribe(EVENT) { raise "compatibility callback failure" }
    later_handle = ActiveSupport::Notifications.monotonic_subscribe(EVENT) { calls += 1 }
    result = capture { instrument }
    ActiveSupport::Notifications.unsubscribe(raised_handle)
    ActiveSupport::Notifications.unsubscribe(later_handle)

    record(
      :callback_exception,
      pass: result[:exception] == "RuntimeError: compatibility callback failure" && calls == 1,
      propagated_exception: result[:exception],
      later_callback_count: calls
    )
  end

  def capture
    value = yield
    { value_class: value.class.name, value_nil: value.nil?, exception: nil }
  rescue StandardError => e
    { value_class: nil, value_nil: nil, exception: "#{e.class}: #{e.message}" }
  end
end

CompatibilityCheck.new.run
