# frozen_string_literal: true

module Karst
  module Access
    class Error < StandardError; end
    class UnsafeTarget < Error; end
    class UnsupportedMethod < Error; end
    class Unavailable < Error; end
  end
end
