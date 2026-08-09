# frozen_string_literal: true

require_relative "../value"

module Karst
  module Sql
    # Minimal immutable evidence captured from a SQL notification.
    Event = Value.define(
      :name,
      :sql,
      :cached,
      :duration_ms,
      :monotonic_started_at
    )
  end
end
