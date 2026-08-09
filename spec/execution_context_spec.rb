# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength

require "spec_helper"
require "karst/execution_context"

RSpec.describe Karst::ExecutionContext do
  after { Karst::ExecutionContext.delete(:karst_execution_context_spec) }

  describe "modern Rails path" do
    it "delegates directly to ActiveSupport::IsolatedExecutionState when it is defined" do
      expect(described_class.const_get(:BACKEND, false)).to equal(ActiveSupport::IsolatedExecutionState)
    end
  end

  describe "read/write/delete" do
    it "returns nil for an unset key" do
      expect(described_class[:karst_execution_context_spec]).to be_nil
    end

    it "round-trips a written value" do
      described_class[:karst_execution_context_spec] = { controller: "X" }

      expect(described_class[:karst_execution_context_spec]).to eq({ controller: "X" })
    end

    it "removes a value on delete, leaving the key unset" do
      described_class[:karst_execution_context_spec] = "value"
      described_class.delete(:karst_execution_context_spec)

      expect(described_class[:karst_execution_context_spec]).to be_nil
    end

    it "overwrites, rather than stacks, a value set again under the same key" do
      described_class[:karst_execution_context_spec] = "first"
      described_class[:karst_execution_context_spec] = "second"

      expect(described_class[:karst_execution_context_spec]).to eq("second")
      described_class.delete(:karst_execution_context_spec)
      expect(described_class[:karst_execution_context_spec]).to be_nil
    end
  end

  # ThreadLocalStore is Karst's Rails 6.1 fallback (see Karst::ExecutionContext),
  # used whenever ActiveSupport::IsolatedExecutionState is unavailable. It is
  # tested directly here, independent of which backend this process actually
  # selected, so its contract is proven on every supported Ruby.
  describe described_class.const_get(:ThreadLocalStore, false) do
    subject(:store) { described_class.new }

    it "returns nil for an unset key" do
      expect(store[:missing]).to be_nil
    end

    it "round-trips a written value" do
      store[:a] = "value"

      expect(store[:a]).to eq("value")
    end

    it "deletes a value, leaving the key unset" do
      store[:a] = "value"
      store.delete(:a)

      expect(store[:a]).to be_nil
    end

    it "keeps distinct keys independent within the same store" do
      store[:a] = "one"
      store[:b] = "two"
      store.delete(:a)

      expect(store[:a]).to be_nil
      expect(store[:b]).to eq("two")
    end

    it "is thread-local: concurrent threads never observe each other's values under the same key" do
      results = Queue.new
      threads = 20.times.map do |i|
        Thread.new do
          store[:concurrent] = i
          sleep(0.001)
          results << [i, store[:concurrent]]
        end
      end
      threads.each(&:join)

      observed = Array.new(20) { results.pop }
      expect(observed.to_h).to eq((0...20).to_h { |i| [i, i] })
    end

    it "cleans up fully after ensure-style set/delete, leaving no residue on the current thread" do
      begin
        store[:ensured] = "temporary"
        raise "boom"
      rescue RuntimeError
        store.delete(:ensured)
      end

      expect(store[:ensured]).to be_nil
    end
  end
end

# rubocop:enable Metrics/BlockLength
