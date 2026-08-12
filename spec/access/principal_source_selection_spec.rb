# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "karst"

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Access::PrincipalSourceSelection do
  around do |example|
    Dir.mktmpdir("karst-principal-selection") do |dir|
      @root = dir
      example.run
    end
  end

  before do
    allow(described_class).to receive(:path)
      .and_return(File.join(@root, "tmp/karst/principal_source_selection.json"))
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
    it "selects nothing, without complaint, before anything has been selected" do
      record = described_class.load

      expect(record.model_names).to be_empty
      expect(record.error).to be_nil
    end
  end

  describe ".replace" do
    it "persists a selection as plain model names, never executable Ruby" do
      described_class.replace(["User"])

      expect(stored).to eq("version" => 1, "selected" => ["User"])
      expect(File.read(described_class.path)).not_to include("->", "lambda", "proc")
    end

    it "reads back what it wrote, so a selection survives a fresh process" do
      described_class.replace(%w[User Admin])

      reloaded = described_class.load

      expect(reloaded.model_names).to eq(%w[Admin User])
      expect(reloaded).to be_selected("User")
      expect(reloaded).to be_selected("Admin")
    end

    it "treats a smaller set as deselection, replacing rather than accumulating" do
      described_class.replace(%w[User Admin])

      described_class.replace(["User"])

      expect(described_class.load.model_names).to eq(["User"])
      expect(described_class.load).not_to be_selected("Admin")
    end

    it "clears every selection when given none" do
      described_class.replace(["User"])

      described_class.replace([])

      expect(described_class.load.model_names).to be_empty
      expect(stored["selected"]).to eq([])
    end

    it "stores one deterministic, deduplicated order regardless of submission order" do
      described_class.replace(%w[User Admin User])

      expect(stored["selected"]).to eq(%w[Admin User])
    end

    it "never writes a name that could not plausibly be a Devise-mapped constant" do
      described_class.replace(["User", "destroy_all; rm -rf", "user.rb", "Admin"])

      expect(stored["selected"]).to eq(%w[Admin User])
    end

    it "reports a failed write instead of pretending a selection was saved" do
      allow(File).to receive(:write).and_raise(Errno::EACCES)

      record = described_class.replace(["User"])

      expect(record.error).to include("could not be saved")
    end

    it "leaves no temporary file behind" do
      described_class.replace(["User"])

      expect(Dir.glob(File.join(File.dirname(described_class.path), "*"))).to eq([described_class.path])
    end
  end

  describe "failing closed on malformed or malicious storage" do
    {
      "unparseable JSON" => "{ not json",
      "a non-document top level" => "[]",
      "an unknown schema version" => '{"version":99,"selected":["User"]}',
      "a missing selection list" => '{"version":1}',
      "a non-string entry in the list" => '{"version":1,"selected":[1]}',
      "an arbitrary expression as an entry" => '{"version":1,"selected":["send(:x)"]}',
      "a lowercase model name" => '{"version":1,"selected":["user"]}',
      "a shell-injection-shaped entry" => '{"version":1,"selected":["User; rm -rf /"]}'
    }.each do |description, content|
      it "selects nothing and explains why, given #{description}" do
        write_raw(content)

        record = described_class.load

        expect(record.model_names).to be_empty
        expect(record.error).to include("selected no principal sources from it")
      end
    end

    it "rejects the whole document rather than partially trusting it" do
      write_raw('{"version":1,"selected":["User","9Bad"]}')

      expect(described_class.load.model_names).to be_empty
    end

    it "rejects a document holding more entries than Karst will consider" do
      selected = Array.new(described_class::MAX_ENTRIES + 1) { |i| "Model#{i}" }
      write_raw(JSON.generate("version" => 1, "selected" => selected))

      expect(described_class.load.model_names).to be_empty
      expect(described_class.load.error).to include("more than #{described_class::MAX_ENTRIES}")
    end

    it "reports an unreadable file rather than raising into the caller" do
      write_raw('{"version":1,"selected":[]}')
      allow(File).to receive(:read).and_raise(Errno::EACCES)

      expect(described_class.load.model_names).to be_empty
      expect(described_class.load.error).to include("could not be read")
    end
  end

  describe ".display_path" do
    it "names the application-relative location a developer can delete" do
      expect(described_class.display_path).to eq("tmp/karst/principal_source_selection.json")
    end
  end
end
# rubocop:enable Metrics/BlockLength
