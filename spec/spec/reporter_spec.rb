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
  def request(sequence: 0, format: "html", role: :subject, principal: nil, status: 200)
    Karst::Spec::RequestObservation.new(
      sequence: sequence, http_method: "GET", path: "/x", route_pattern: "/x(.:format)",
      controller: "XController", action: "show", format: format,
      status: status, redirect_location: nil, role: role, principal: principal
    )
  end

  def example(file_path:, line_number:, description: "does a thing", requests: [request])
    Karst::Spec::ExampleObservation.new(
      example_id: "./#{file_path}[1:1]", file_path: file_path, line_number: line_number,
      spec_type: :request, description_parts: ["Group", description],
      full_description: "Group #{description}", outcome: :passed, requests: requests
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

    it "serializes a principal as type/id/scope only" do
      reporter = described_class.new
      principal = Karst::Spec::Principal.new(type: "User", id: 42, scope: :user)
      reporter.record(
        example(file_path: "spec/a_spec.rb", line_number: 1, requests: [request(principal: principal)])
      )

      Dir.mktmpdir do |dir|
        path = File.join(dir, "scenarios.json")
        reporter.write(path)
        written = JSON.parse(File.read(path))

        expect(written.first["requests"].first["principal"]).to eq(
          { "type" => "User", "id" => 42, "scope" => "user" }
        )
      end
    end

    it "serializes a nil principal as null, and role/format/outcome as strings" do
      reporter = described_class.new
      reporter.record(example(file_path: "spec/a_spec.rb", line_number: 1))

      Dir.mktmpdir do |dir|
        path = File.join(dir, "scenarios.json")
        reporter.write(path)
        written = JSON.parse(File.read(path))
        request_json = written.first["requests"].first

        expect(request_json["principal"]).to be_nil
        expect(request_json["role"]).to eq("subject")
        expect(request_json["format"]).to eq("html")
        expect(written.first["outcome"]).to eq("passed")
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
