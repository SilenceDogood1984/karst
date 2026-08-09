# frozen_string_literal: true

require "yaml"
require "karst"

# The examples deliberately keep the three reviewable corpora beside their execution logic.
# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Sql.const_get(:Canonicalizer, false) do
  subject(:canonicalize) { described_class.method(:call) }

  corpus = YAML.safe_load_file(File.expand_path("../fixtures/sql_canonicalization.yml", __dir__))

  corpus.each do |example|
    it example.fetch("reason") do
      expect(canonicalize.call(example.fetch("input"))).to eq(example.fetch("expected"))
    end
  end

  it "returns a distinct frozen string without mutating the input" do
    sql = +"SELECT 1"
    result = canonicalize.call(sql)

    expect(result).to eq("SELECT ?")
    expect(result).to be_frozen
    expect(result).not_to equal(sql)
    expect(sql).to eq("SELECT 1")
  end

  it "returns a distinct string even when no transformation is needed" do
    sql = +"SELECT * FROM users"

    expect(canonicalize.call(sql)).not_to equal(sql)
  end

  it "rejects non-String input rather than coercing it" do
    expect { canonicalize.call(:select) }.to raise_error(ArgumentError, "sql must be a String")
  end

  it "classifies tokens at index zero independently of trailing characters" do
    {
      "5" => "?",
      "5)" => "?)",
      "5 FROM t" => "? FROM t",
      "true" => "?"
    }.each do |input, expected|
      expect(canonicalize.call(input)).to eq(expected)
    end
  end

  it "declines malformed or dialect-ambiguous input instead of returning a canonical prefix" do
    adversarial_inputs = [
      "SELECT * FROM t WHERE pw = 'hunter2",
      "UPDATE t SET token = 'abc123",
      "SELECT `col FROM t WHERE pw = 'secret'",
      "SELECT \"col FROM t WHERE token = 'secret-token'",
      "SELECT /* comment token='secret-token'",
      "SELECT * FROM t WHERE path = 'C:\\' AND secret = 'hunter2'",
      "UPDATE files SET dir = 'C:\\' WHERE token = 'abc123'",
      "SELECT $tag$secret-token"
    ]

    expect(adversarial_inputs.map { |input| canonicalize.call(input) }).to all(be_nil)
  end

  it "does not collapse structurally different statements after ambiguous backslash literals" do
    statements = [
      "SELECT * FROM users WHERE name LIKE 'foo\\_bar%' ORDER BY id ASC LIMIT 25",
      "SELECT * FROM users WHERE name LIKE 'baz%qux%' ORDER BY created\\_at DESC LIMIT 10 OFFSET 50"
    ]

    expect(statements.map { |sql| canonicalize.call(sql) }).to eq([nil, nil])
  end

  it "propagates a decline from inside a semantic comment" do
    expect(canonicalize.call("SELECT /*! name = 'ambiguous\\_value' */ 1")).to be_nil
  end

  equivalence_pairs = [
    ["SELECT * FROM users WHERE id = 1", "SELECT * FROM users WHERE id = 999"],
    ["SELECT * FROM users WHERE email = 'a@example.com'", "SELECT * FROM users WHERE email = 'b@example.com'"],
    ["SELECT * FROM users WHERE active = TRUE", "SELECT * FROM users WHERE active = FALSE"],
    ["SELECT * FROM users LIMIT 10 OFFSET 0", "SELECT * FROM users LIMIT 50 OFFSET 100"],
    ["INSERT INTO logs (message) VALUES ('first')", "INSERT INTO logs (message) VALUES ('second')"],
    ["SELECT * FROM users /* trace=a */ WHERE id = 1", "SELECT * FROM users -- trace=b\nWHERE id = 2"]
  ]

  equivalence_pairs.each_with_index do |(left, right), index|
    it "canonicalizes required equivalence pair #{index + 1} identically" do
      expect(canonicalize.call(left)).to eq(canonicalize.call(right))
    end
  end

  non_equivalence_pairs = [
    ["WHERE deleted_at IS NULL", "WHERE deleted_at IS NOT NULL"],
    ["WHERE id IN (?, ?)", "WHERE id IN (?, ?, ?)"],
    ["ORDER BY created_at ASC", "ORDER BY created_at DESC"],
    ["SELECT users.id", "SELECT accounts.id"],
    ["SELECT ?::uuid", "SELECT ?::text"],
    ["select * from users", "SELECT * FROM users"],
    ["SELECT /*+ INDEX(users first_idx) */ * FROM users", "SELECT /*+ INDEX(users second_idx) */ * FROM users"]
  ]

  non_equivalence_pairs.each_with_index do |(left, right), index|
    it "preserves required distinction #{index + 1}" do
      expect(canonicalize.call(left)).not_to eq(canonicalize.call(right))
    end
  end
end
# rubocop:enable Metrics/BlockLength
