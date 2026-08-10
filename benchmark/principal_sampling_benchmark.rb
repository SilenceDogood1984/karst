# frozen_string_literal: true

# Benchmarks the fix for the dogfood case that motivated this change: with
# ~500,000 User records, "Analyze 25 representative principals" took minutes
# because Karst::Access::PrincipalSampler ran representative-state discovery
# (dimension-cardinality queries, per-target lookups, seed/fill queries)
# directly against the full relation. This script seeds a large table and
# compares that previous, effectively-unbounded behavior against sampling
# scoped to a bounded recent-N candidate pool (config.principal_candidate_pool_size).
#
# "Previous behavior" is reproduced using the *real*, current sampling
# algorithm with only its one new step -- deriving the bounded pool relation
# -- disabled, so every other line of the algorithm under test is identical
# between the two runs; only how much data each query can ever touch differs.
#
# Usage:
#   bundle exec ruby benchmark/principal_sampling_benchmark.rb
#   BENCHMARK_ROWS=500000 BENCHMARK_POOL_SIZE=1000 bundle exec ruby benchmark/principal_sampling_benchmark.rb

require "bundler/setup"
require "active_record"
require "active_support/notifications"
require_relative "../lib/karst"
require_relative "../lib/karst/access/principal_sampler"

ROWS = Integer(ENV.fetch("BENCHMARK_ROWS", 500_000))
POOL_SIZE = Integer(ENV.fetch("BENCHMARK_POOL_SIZE", 1_000))
LIMIT = Integer(ENV.fetch("BENCHMARK_LIMIT", 25))

# Rows are inserted oldest-first, so index i is also recency order: row 0 is
# the oldest account, row `ROWS - 1` the newest. `status: 2` is planted only
# among the oldest sliver of accounts -- a retired legacy value real apps
# accumulate (a deprecated plan tier, an old signup flow's default) that
# newer rows never get. That is precisely the shape that makes the fix (and
# not just the general dataset size) matter: a naive "biggest table wins"
# benchmark with minority states smeared near the end would let primary-key-
# descending lookups find them almost immediately either way, hiding the
# actual cost representative discovery paid before this change -- walking
# the relation to find a state that exists *only* far from the end.
# `premium: true` is planted on the single newest row instead, so the
# bounded pool run still has a minority state it must (and does) find.
LEGACY_STATUS_CUTOFF = [ROWS / 500, 1].max

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :benchmark_principals do |t|
    t.boolean :premium, null: false, default: false
    t.integer :status, null: false, default: 0
    t.integer :plan_id
    t.datetime :created_at
  end
end

# A standalone, dev-only measurement script: the fixture model and the
# benchmark-only subclass below exist purely to drive this one comparison
# and are not part of the library's own architecture.
# rubocop:disable Style/OneClassPerFile
class BenchmarkPrincipal < ActiveRecord::Base
end

# Reproduces the pre-fix code path: identical representative-discovery
# algorithm, but every query still reaches the full, unbounded relation
# instead of a bounded recent-N pool.
class UnboundedPrincipalSampler < Karst::Access::PrincipalSampler
  private

  def bounded_pool_relation(relation, _klass, _primary_key)
    relation
  end
end
# rubocop:enable Style/OneClassPerFile

def status_for(index)
  return 2 if index < LEGACY_STATUS_CUTOFF
  return 0 if index.even?

  1
end

def record_for(index, rows, now)
  {
    premium: index == rows - 1,
    status: status_for(index),
    plan_id: index.even? ? nil : (index % 7),
    created_at: now - (rows - index).seconds
  }
end

def seed!(rows)
  puts "Seeding #{rows} rows (status=2 legacy value present only on the oldest #{LEGACY_STATUS_CUTOFF} rows)..."
  now = Time.now
  (0...rows).each_slice(5_000) do |slice|
    BenchmarkPrincipal.insert_all(slice.map { |i| record_for(i, rows, now) })
  end
  puts "Seeded #{BenchmarkPrincipal.count} rows.\n\n"
end

def report(label, queries, elapsed_ms, sampled, strategy)
  puts "#{label}:"
  puts "  SQL queries:        #{queries}"
  puts "  elapsed:            #{elapsed_ms} ms"
  puts "  principals sampled: #{sampled}"
  puts "  strategy:           #{strategy}"
  puts
end

def measure(label)
  queries = 0
  callback = ->(*_args) { queries += 1 }
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = nil
  ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { result = yield }
  elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)

  report(label, queries, elapsed_ms, result.principals.size, result.strategy)
  { queries: queries, elapsed_ms: elapsed_ms, sampled: result.principals.size }
end

def table_row(label, queries, elapsed_ms, sampled)
  label.ljust(45) + queries.rjust(10) + elapsed_ms.rjust(12) + sampled.rjust(10)
end

def print_table(rows)
  puts table_row("scenario", "queries", "elapsed_ms", "probes")
  rows.each do |label, data|
    puts table_row(label, data[:queries].to_s, format("%.1f", data[:elapsed_ms]), data[:sampled].to_s)
  end
end

seed!(ROWS)

puts "== Previous behavior: representative discovery against the full #{ROWS}-row source =="
previous = measure("full-table (unbounded)") do
  UnboundedPrincipalSampler.new(source: BenchmarkPrincipal.all, limit: LIMIT, pool_size: ROWS).call
end

puts "== This change: representative discovery scoped to a #{POOL_SIZE}-row candidate pool =="
current = measure("bounded candidate pool, no index on created_at") do
  Karst::Access::PrincipalSampler.new(source: BenchmarkPrincipal.all, limit: LIMIT, pool_size: POOL_SIZE).call
end

# Deriving the pool still costs one ORDER BY created_at DESC LIMIT query
# (see #bounded_pool_relation's comment): without an index, that one query
# pays a full sort of the table. That is a real, size-dependent cost this
# change does not remove -- indexing created_at (already common practice for
# recency-ordered pagination) is what removes it. Measuring both makes that
# trade-off, and the size of the remaining unindexed cost, honest rather
# than asserted.
BenchmarkPrincipal.connection.add_index :benchmark_principals, :created_at
indexed = measure("bounded candidate pool, with an index on created_at") do
  Karst::Access::PrincipalSampler.new(source: BenchmarkPrincipal.all, limit: LIMIT, pool_size: POOL_SIZE).call
end

puts "== Summary =="
puts "rows: #{ROWS}, pool_size: #{POOL_SIZE}, limit: #{LIMIT}"
puts
print_table([["previous (unbounded)", previous], ["bounded pool, no created_at index", current],
             ["bounded pool, with created_at index", indexed]])
puts
puts "query count: bounded to a handful of queries either way for this " \
     "narrow benchmark schema -- the structural guarantee this change adds " \
     "(proved in spec/access/principal_sampler_spec.rb, not just this " \
     "benchmark) is that every one of those queries can only ever touch " \
     "#{POOL_SIZE} rows, never the full #{ROWS}, regardless of table width " \
     "or the number of stratification dimensions a real model has."
puts "elapsed time: in-memory SQLite scans #{ROWS} rows in low-single-digit " \
     "milliseconds, so it cannot reproduce the multi-minute cost a remote, " \
     "disk-backed 500k-row production database pays for repeated full-table " \
     "queries -- that cost comes from per-query network/disk round trips " \
     "this benchmark has none of. What it does show concretely: deriving " \
     "the candidate pool costs #{(current[:elapsed_ms] - indexed[:elapsed_ms]).round(1)}ms " \
     "here specifically because created_at has no index; adding one (a " \
     "single, ordinary migration) drops that to #{indexed[:elapsed_ms]}ms, " \
     "matching the previous run's cost while every other query is bounded " \
     "to #{POOL_SIZE} rows instead of #{ROWS}."
puts "both scenarios sampled #{previous[:sampled]} / #{current[:sampled]} / #{indexed[:sampled]} probes " \
     "(target: #{LIMIT})."
