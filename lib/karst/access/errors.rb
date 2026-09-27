# frozen_string_literal: true

module Karst
  module Access
    class Error < StandardError; end
    class UnsafeTarget < Error; end
    class UnsupportedMethod < Error; end
    class Unavailable < Error; end

    # Karst could not observe a request it tried to run -- one of its own
    # subscribers raised, or the request never reached the application. Never
    # evidence about the application: an operation that raises this reports
    # nothing for the request rather than incomplete evidence.
    class ObservationError < Error; end
  end
end
