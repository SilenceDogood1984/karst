# frozen_string_literal: true

module Karst
  module Spec
    # Minimal principal evidence observed via Warden's public hooks during an
    # RSpec example: class name and primary key only, never a serialized user
    # object, mirroring Karst's runtime-evidence principal model.
    Principal = Data.define(:type, :id, :scope)
  end
end
