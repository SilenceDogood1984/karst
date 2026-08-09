# frozen_string_literal: true

require_relative "../value"

module Karst
  module Spec
    # Minimal principal evidence observed via Warden's public hooks during an
    # RSpec example: class name and primary key only, never a serialized user
    # object, mirroring Karst's runtime-evidence principal model.
    Principal = Value.define(:type, :id, :scope)
  end
end
