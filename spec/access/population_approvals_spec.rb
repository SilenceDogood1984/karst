# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "karst"

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Access::PopulationApprovals do
  around do |example|
    Dir.mktmpdir("karst-approvals") do |dir|
      @root = dir
      example.run
    end
  end

  before do
    allow(described_class).to receive(:path).and_return(File.join(@root, "tmp/karst/approved_populations.json"))
  end

  def entry(model_name, method_name)
    described_class::Entry.new(model_name: model_name, method_name: method_name)
  end

  def write_raw(content)
    path = described_class.path
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def stored
    JSON.parse(File.read(described_class.path))
  end

  describe ".load" do
    it "approves nothing, without complaint, before anything has been approved" do
      record = described_class.load

      expect(record.entries).to be_empty
      expect(record.error).to be_nil
    end
  end

  describe ".replace" do
    it "persists an approval as plain model and scope names, never executable Ruby" do
      described_class.replace([entry("User", "system_admins")])

      expect(stored).to eq("version" => 1, "approved" => [{ "model" => "User", "scope" => "system_admins" }])
      expect(File.read(described_class.path)).not_to include("->", "lambda", "proc")
    end

    it "reads back what it wrote, so an approval survives a fresh process" do
      described_class.replace([entry("User", "system_admins"), entry("User", "auditors")])

      reloaded = described_class.load

      expect(reloaded.entries.map(&:display_label)).to eq(["User.auditors", "User.system_admins"])
      expect(reloaded).to be_approved("User", :system_admins)
    end

    it "treats a smaller set as unapproval, replacing rather than accumulating" do
      described_class.replace([entry("User", "system_admins"), entry("User", "auditors")])

      described_class.replace([entry("User", "auditors")])

      expect(described_class.load.entries.map(&:display_label)).to eq(["User.auditors"])
      expect(described_class.load).not_to be_approved("User", "system_admins")
    end

    it "clears every approval when given none" do
      described_class.replace([entry("User", "system_admins")])

      described_class.replace([])

      expect(described_class.load.entries).to be_empty
      expect(stored["approved"]).to eq([])
    end

    it "stores one deterministic, deduplicated order regardless of submission order" do
      described_class.replace([entry("User", "system_admins"), entry("Admin", "active"),
                               entry("User", "system_admins")])

      expect(stored["approved"]).to eq([{ "model" => "Admin", "scope" => "active" },
                                        { "model" => "User", "scope" => "system_admins" }])
    end

    it "never writes an entry whose names could not have come from discovery" do
      described_class.replace([entry("User", "destroy_all; rm -rf"), entry("user.rb", "admins"),
                               entry("User", "auditors")])

      expect(stored["approved"]).to eq([{ "model" => "User", "scope" => "auditors" }])
    end

    it "reports a failed write instead of pretending an approval was saved" do
      allow(File).to receive(:write).and_raise(Errno::EACCES)

      record = described_class.replace([entry("User", "system_admins")])

      expect(record.error).to include("could not be saved")
    end

    it "leaves no temporary file behind" do
      described_class.replace([entry("User", "system_admins")])

      expect(Dir.glob(File.join(File.dirname(described_class.path), "*"))).to eq([described_class.path])
    end
  end

  describe "failing closed on malformed storage" do
    {
      "unparseable JSON" => "{ not json",
      "a non-document top level" => "[]",
      "an unknown schema version" => '{"version":99,"approved":[{"model":"User","scope":"admins"}]}',
      "a missing approval list" => '{"version":1}',
      "a non-entry in the list" => '{"version":1,"approved":["User.admins"]}',
      "a non-string model" => '{"version":1,"approved":[{"model":1,"scope":"admins"}]}',
      "an arbitrary expression as a scope" => '{"version":1,"approved":[{"model":"User","scope":"send(:x)"}]}',
      "a lowercase model name" => '{"version":1,"approved":[{"model":"user","scope":"admins"}]}'
    }.each do |description, content|
      it "approves nothing and explains why, given #{description}" do
        write_raw(content)

        record = described_class.load

        expect(record.entries).to be_empty
        expect(record.error).to include("approved no populations from it")
      end
    end

    it "rejects the whole document rather than partially trusting it" do
      write_raw('{"version":1,"approved":[{"model":"User","scope":"admins"},{"model":"User","scope":"9bad"}]}')

      expect(described_class.load.entries).to be_empty
    end

    it "rejects a document holding more entries than Karst will consider" do
      approved = Array.new(described_class::MAX_ENTRIES + 1) { |i| { "model" => "User", "scope" => "scope_#{i}" } }
      write_raw(JSON.generate("version" => 1, "approved" => approved))

      expect(described_class.load.entries).to be_empty
      expect(described_class.load.error).to include("more than #{described_class::MAX_ENTRIES}")
    end

    it "reports an unreadable file rather than raising into the caller" do
      write_raw('{"version":1,"approved":[]}')
      allow(File).to receive(:read).and_raise(Errno::EACCES)

      expect(described_class.load.entries).to be_empty
      expect(described_class.load.error).to include("could not be read")
    end
  end

  describe ".display_path" do
    it "names the application-relative location a developer can delete" do
      expect(described_class.display_path).to eq("tmp/karst/approved_populations.json")
    end
  end
end
# rubocop:enable Metrics/BlockLength
