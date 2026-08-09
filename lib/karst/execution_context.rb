# frozen_string_literal: true

begin
  require "active_support/isolated_execution_state"
rescue LoadError
  # Rails 6.1 does not ship this file (added in Rails 7.0). The thread-local
  # fallback below (Karst::ExecutionContext::ThreadLocalStore) stands in for
  # it on that series.
end

module Karst
  # Request-local correlation storage used by the page badge and the RSpec
  # scenario observer to carry evidence from a notification callback (fired
  # nested inside a Rack call or an RSpec example) back out to the code that
  # reads it, without a global mutable variable that would let concurrent
  # requests or examples cross-contaminate each other.
  #
  # Modern Rails already solves exactly this with
  # ActiveSupport::IsolatedExecutionState, so Karst simply delegates to it
  # when present. Rails 6.1 does not provide that API, so Karst falls back to
  # ThreadLocalStore, a plain per-Thread Hash reached through
  # Thread#thread_variable_get/set -- never Thread#[]/[]=, which are
  # fiber-local and would silently miss context under a Fiber scheduler.
  # This mirrors ActiveSupport::IsolatedExecutionState's own default :thread
  # isolation level: storage is shared by every Fiber running on one OS
  # thread, not isolated per Fiber. Karst's own usage (one badge or spec
  # correlation captured and read back within a single synchronous
  # request/example) never spans multiple concurrently-scheduled Fibers, so
  # this fallback has no observable effect on Karst's supported behavior. It
  # is documented here so a future caller does not assume Fiber isolation
  # this fallback cannot provide.
  module ExecutionContext
    # Deliberately its own class, rather than inlined into
    # ExecutionContext's own singleton methods, so its behavior is directly
    # testable on every supported Ruby regardless of which backend
    # ExecutionContext itself selects in a given process.
    class ThreadLocalStore
      THREAD_VARIABLE = :karst_execution_context
      private_constant :THREAD_VARIABLE

      def [](key)
        store[key]
      end

      def []=(key, value)
        store[key] = value
      end

      def delete(key)
        store.delete(key)
      end

      private

      def store
        Thread.current.thread_variable_get(THREAD_VARIABLE) ||
          Thread.current.thread_variable_set(THREAD_VARIABLE, {})
      end
    end
    private_constant :ThreadLocalStore

    BACKEND = if defined?(ActiveSupport::IsolatedExecutionState)
                ActiveSupport::IsolatedExecutionState
              else
                ThreadLocalStore.new
              end
    private_constant :BACKEND

    class << self
      def [](key)
        BACKEND[key]
      end

      def []=(key, value)
        BACKEND[key] = value
      end

      def delete(key)
        BACKEND.delete(key)
      end
    end
  end
end
