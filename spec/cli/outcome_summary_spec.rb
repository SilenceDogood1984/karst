# frozen_string_literal: true

require "spec_helper"
require "karst"
require "karst/cli/outcome_summary"

# rubocop:disable Metrics/BlockLength, Metrics/ParameterLists
RSpec.describe Karst::CLI::OutcomeSummary do
  def outcome(id, status: 403, callback: :require_admin, exception: nil, redirect: nil, writes: 0)
    Karst::Access::Outcome.new(
      principal: Karst::Identity::PrincipalDescriptor.new(model_name: "User", id: id, display_label: "User ##{id}"),
      status: status, redirect: redirect, exception_class: exception, writes_observed: writes.positive?,
      write_count: writes, elapsed_ms: rand * 20, database_rollback_attempted: true, sampling_reasons: [],
      halted_callback: callback, identity: nil, controller: "ReportsController",
      action: "show"
    )
  end

  def allowed(id)
    outcome(id, status: 200, callback: nil)
  end

  def summary(outcomes)
    groups = Karst::Access::OutcomeGroups.group(outcomes, usable: Karst.config.usable_access_outcome)
    described_class.new(groups).lines
  end

  it "summarizes 1 identity as one outcome line, without listing the user" do
    lines = summary([outcome(1)])

    expect(lines).to eq(["  1  403 Forbidden · halted at require_admin"])
  end

  it "summarizes 10 identities with one outcome as a single line" do
    lines = summary((1..10).map { |id| outcome(id) })

    expect(lines).to eq(["  10  403 Forbidden · halted at require_admin"])
  end

  it "summarizes 100 identities with 2 outcomes in a few lines, naming only users outside the largest outcome" do
    lines = summary((1..58).map { |id| outcome(id) } + (59..100).map { |id| allowed(id) })

    expect(lines.size).to eq(3)
    expect(lines[0]).to eq("  58  403 Forbidden · halted at require_admin")
    expect(lines[1]).to eq("  42  200 OK · verified usable")
    expect(lines[2]).to include("User #59, User #60, User #61, +39 more")
    expect(lines.join).not_to include("User #1,")
  end

  it "keeps a rare minority visible, with the users worth inspecting" do
    lines = summary((1..42).map { |id| outcome(id) } + [allowed(43)] +
                    [outcome(44, status: nil, callback: nil, exception: "NoMethodError"),
                     outcome(45, status: nil, callback: nil, exception: "NoMethodError")])

    expect(lines).to eq([
                          "  42  403 Forbidden · halted at require_admin",
                          "   2  exception NoMethodError",
                          "        User #44, User #45",
                          "   1  200 OK · verified usable",
                          "        User #43"
                        ])
  end

  it "stays bounded for many identities with many rare outcomes, and never hides a usable one" do
    rare = (1..20).map do |id|
      outcome(100 + id, status: nil, callback: nil, exception: "Error#{id.to_s.rjust(2, '0')}")
    end
    lines = summary((1..79).map { |id| outcome(id) } + rare + [allowed(200)])

    expect(lines.size).to be <= ((described_class::MAX_OUTCOMES + 1) * 2) + 1
    expect(lines.first).to eq("  79  403 Forbidden · halted at require_admin")
    expect(lines.join("\n")).to include("200 OK · verified usable", "User #200")
    expect(lines.last).to eq("  +16 more outcomes (16 users); --json lists every outcome")
  end

  it "does not single out a largest outcome when the largest count is tied" do
    lines = summary((1..3).map { |id| outcome(id) } + (4..6).map { |id| allowed(id) })

    expect(lines).to eq([
                          "  3  200 OK · verified usable",
                          "       User #4, User #5, User #6",
                          "  3  403 Forbidden · halted at require_admin",
                          "       User #1, User #2, User #3"
                        ])
  end

  it "reports a close split as plain counts, without any dominance wording" do
    lines = summary((1..12).map { |id| allowed(id) } + (13..23).map { |id| outcome(id) } +
                    (24..32).map { |id| outcome(id, status: 302, redirect: "/login", callback: :authenticate) })

    expect(lines.grep(/\A +\d+  /).map { |line| line[/\d+/].to_i }).to eq([12, 11, 9])
    expect(lines.join).not_to match(/dominant|most|majority|typical|%/i)
  end

  it "says what was written, and never renders two different groups identically" do
    lines = summary([outcome(1), outcome(2, writes: 2)])

    expect(lines.grep(/  1  /).uniq.size).to eq(2)
    expect(lines.join).to include("halted at require_admin · 2 database writes")
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/ParameterLists
