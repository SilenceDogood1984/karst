# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "karst"
require "karst/spec/principal"
require "karst/spec/request_observation"
require "karst/spec/example_observation"
require "karst/spec/reporter"

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Spec::Reporter do
  def request(sequence: 0, format: "html", principal_before: nil, principal_after: nil, status: 200)
    Karst::Spec::RequestObservation.new(
      sequence: sequence, http_method: "GET", path: "/x", route_pattern: "/x(.:format)",
      controller: "XController", action: "show", format: format,
      status: status, redirect_location: nil,
      principal_before: principal_before, principal_after: principal_after,
      principal_changed: principal_before != principal_after
    )
  end

  def example(file_path:, line_number:, description: "does a thing", requests: [request], karst: nil)
    Karst::Spec::ExampleObservation.new(
      example_id: "./#{file_path}[1:1]", file_path: file_path, line_number: line_number,
      spec_type: :request, description_parts: ["Group", description],
      full_description: "Group #{description}", karst_explicit: !karst.nil?, karst_name: karst,
      outcome: :passed, requests: requests
    )
  end

  describe "#record and #to_a" do
    it "retains every recorded example, in recorded order" do
      reporter = described_class.new
      first = example(file_path: "spec/a_spec.rb", line_number: 1)
      second = example(file_path: "spec/a_spec.rb", line_number: 2)

      reporter.record(first)
      reporter.record(second)

      expect(reporter.to_a).to eq([first, second])
    end
  end

  describe "#write" do
    it "writes only browser-facing examples" do
      reporter = described_class.new
      reporter.record(example(file_path: "spec/a_spec.rb", line_number: 1, requests: [request(format: "html")]))
      reporter.record(example(file_path: "spec/a_spec.rb", line_number: 2, requests: [request(format: "json")]))

      Dir.mktmpdir do |dir|
        path = File.join(dir, "scenarios.json")
        reporter.write(path)
        written = JSON.parse(File.read(path))

        expect(written.size).to eq(1)
        expect(written.first["line_number"]).to eq(1)
      end
    end

    it "orders examples by file path then line number, independent of recording order" do
      reporter = described_class.new
      reporter.record(example(file_path: "spec/b_spec.rb", line_number: 1))
      reporter.record(example(file_path: "spec/a_spec.rb", line_number: 20))
      reporter.record(example(file_path: "spec/a_spec.rb", line_number: 5))

      Dir.mktmpdir do |dir|
        path = File.join(dir, "scenarios.json")
        reporter.write(path)
        written = JSON.parse(File.read(path))

        expect(written.map { |ex| [ex["file_path"], ex["line_number"]] }).to eq(
          [["spec/a_spec.rb", 5], ["spec/a_spec.rb", 20], ["spec/b_spec.rb", 1]]
        )
      end
    end

    it "creates intermediate directories for the output path" do
      reporter = described_class.new
      reporter.record(example(file_path: "spec/a_spec.rb", line_number: 1))

      Dir.mktmpdir do |dir|
        path = File.join(dir, "nested", "deeper", "scenarios.json")
        reporter.write(path)

        expect(File).to exist(path)
      end
    end

    it "serializes principal_before/after as type/id/scope only, and principal_changed as a boolean" do
      reporter = described_class.new
      before_principal = Karst::Spec::Principal.new(type: "User", id: 41, scope: :user)
      after_principal = Karst::Spec::Principal.new(type: "User", id: 42, scope: :user)
      reporter.record(
        example(
          file_path: "spec/a_spec.rb", line_number: 1,
          requests: [request(principal_before: before_principal, principal_after: after_principal)]
        )
      )

      Dir.mktmpdir do |dir|
        path = File.join(dir, "scenarios.json")
        reporter.write(path)
        written = JSON.parse(File.read(path))
        request_json = written.first["requests"].first

        expect(request_json["principal_before"]).to eq({ "type" => "User", "id" => 41, "scope" => "user" })
        expect(request_json["principal_after"]).to eq({ "type" => "User", "id" => 42, "scope" => "user" })
        expect(request_json["principal_changed"]).to be(true)
      end
    end

    it "serializes nil principals as null, and format/outcome as strings" do
      reporter = described_class.new
      reporter.record(example(file_path: "spec/a_spec.rb", line_number: 1))

      Dir.mktmpdir do |dir|
        path = File.join(dir, "scenarios.json")
        reporter.write(path)
        written = JSON.parse(File.read(path))
        request_json = written.first["requests"].first

        expect(request_json["principal_before"]).to be_nil
        expect(request_json["principal_after"]).to be_nil
        expect(request_json["principal_changed"]).to be(false)
        expect(request_json["format"]).to eq("html")
        expect(written.first["outcome"]).to eq("passed")
        expect(written.first).to include("karst_explicit" => false, "karst_name" => nil)
      end
    end

    it "serializes explicit Karst scenario metadata" do
      reporter = described_class.new
      reporter.record(
        example(file_path: "spec/a_spec.rb", line_number: 1,
                karst: "Author with no books")
      )

      Dir.mktmpdir do |dir|
        path = File.join(dir, "scenarios.json")
        reporter.write(path)
        written = JSON.parse(File.read(path)).first

        expect(written).to include("karst_explicit" => true, "karst_name" => "Author with no books")
      end
    end

    it "returns the written path" do
      reporter = described_class.new
      reporter.record(example(file_path: "spec/a_spec.rb", line_number: 1))

      Dir.mktmpdir do |dir|
        path = File.join(dir, "scenarios.json")
        expect(reporter.write(path)).to eq(path)
      end
    end
  end
end
# rubocop:enable Metrics/BlockLength
