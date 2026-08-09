# frozen_string_literal: true

module Karst
  # Bounded transient in-process retention of recently captured evidence.
  class Buffer
    attr_reader :capacity

    def initialize(capacity:)
      raise ArgumentError, "capacity must be a positive Integer" unless capacity.is_a?(Integer) && capacity.positive?

      @capacity = capacity
      @events = []
      @mutex = Mutex.new
    end

    # Ingestion path used by Subscription. Kept public: Subscription invokes it as a
    # plain method call on its configured receiver, and making it private would require
    # changing Subscription's call site, which this change intentionally leaves untouched.
    def call(event)
      @mutex.synchronize do
        @events << event
        @events.shift if @events.length > @capacity
      end

      self
    end

    def to_a
      @mutex.synchronize { @events.dup }
    end

    def clear
      @mutex.synchronize { @events.clear }
      self
    end

    def size
      @mutex.synchronize { @events.size }
    end
  end
end
