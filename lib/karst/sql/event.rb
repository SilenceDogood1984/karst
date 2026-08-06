# frozen_string_literal: true

module Karst
  module Sql
    # Minimal immutable evidence captured from a SQL notification.
    Event = Data.define(
      :name,
      :sql,
      :cached,
      :duration_ms,
      :started_at
    )
  end
end
