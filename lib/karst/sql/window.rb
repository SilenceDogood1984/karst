# frozen_string_literal: true

require_relative "../value"

module Karst
  module Sql
    # One immutable, point-in-time snapshot of currently retained SQL evidence.
    # Built once per Karst.window call from a single Buffer#to_a read; carries no
    # state beyond what that snapshot supports.
    Window = Value.define(
      :shapes,
      :declined,
      :event_count,
      :capacity,
      :saturated
    )
  end
end
