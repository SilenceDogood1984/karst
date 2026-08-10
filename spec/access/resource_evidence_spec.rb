# frozen_string_literal: true

require "spec_helper"
require "logger"
require "active_record"
require "action_controller/metal/exceptions"
require "karst"

# A dedicated, isolated Active Record connection -- deliberately not
# ActiveRecord::Base itself -- so this file's schema/fixtures can never
# collide with any other spec file's global AR::Base connection state,
# regardless of randomized spec order (see the identical pattern in
# spec/access/principal_sampler_spec.rb).
class ResourceEvidenceFixtureRecord < ActiveRecord::Base
  self.abstract_class = true
  establish_connection(adapter: "sqlite3", database: ":memory:")
end

class EvidenceUser < ResourceEvidenceFixtureRecord
end

# Deliberately no `belongs_to :user` declared: ResourceEvidence works off
# foreign-key column-name convention against the given records' real
# classes, never off declared associations.
class EvidenceDocument < ResourceEvidenceFixtureRecord
end

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Access::ResourceEvidence do
  before(:all) do
    ResourceEvidenceFixtureRecord.connection.create_table :evidence_users, force: true do |t|
      t.string :name
      t.string :email
    end
    ResourceEvidenceFixtureRecord.connection.create_table :evidence_documents, force: true do |t|
      t.integer :evidence_user_id
      t.string :title
    end
  end

  after(:all) do
    ResourceEvidenceFixtureRecord.connection.drop_table :evidence_users, if_exists: true
    ResourceEvidenceFixtureRecord.connection.drop_table :evidence_documents, if_exists: true
  end

  after do
    EvidenceUser.delete_all
    EvidenceDocument.delete_all
  end

  describe "#call" do
    it "reports an observed foreign key on the resource pointing at the principal" do
      user = EvidenceUser.create!(name: "Ada", email: "ada@example.com")
      document = EvidenceDocument.create!(evidence_user_id: user.id, title: "Notes")

      result = described_class.new(resource: document, principal: user).call(observed_status: 200)

      expect(result.resource).to eq(Karst::Access::ResourceEvidence::ResourceDescriptor.new(
                                      model_name: "EvidenceDocument", id: document.id
                                    ))
      expect(result.principal.display_label).to eq("EvidenceUser ##{user.id}")
      expect(result.relationships).to contain_exactly(
        have_attributes(column: "evidence_user_id", from_model: "EvidenceDocument", from_id: document.id,
                        to_model: "EvidenceUser", to_id: user.id)
      )
      expect(result.limitation).to be_nil
      expect(result).to be_frozen
      expect(result.relationships).to all(be_frozen)
    end

    it "reports an observed foreign key on the principal pointing at the resource" do
      document = EvidenceDocument.create!(title: "Notes")
      user = EvidenceUser.create!(name: "Ada", email: "ada@example.com")
      # No declared association either way; only the column name/value pairing matters.
      allow(user).to receive_messages(evidence_document_id: document.id)
      allow(EvidenceUser).to receive(:columns_hash).and_return(
        EvidenceUser.columns_hash.merge(
          "evidence_document_id" => instance_double(ActiveRecord::ConnectionAdapters::Column,
                                                    name: "evidence_document_id")
        )
      )

      result = described_class.new(resource: document, principal: user).call

      expect(result.relationships).to contain_exactly(
        have_attributes(column: "evidence_document_id", from_model: "EvidenceUser", from_id: user.id,
                        to_model: "EvidenceDocument", to_id: document.id)
      )
    end

    it "reports no relationship when no foreign-key column value actually matches" do
      user = EvidenceUser.create!(name: "Ada", email: "ada@example.com")
      other_user = EvidenceUser.create!(name: "Grace", email: "grace@example.com")
      document = EvidenceDocument.create!(evidence_user_id: other_user.id, title: "Notes")

      result = described_class.new(resource: document, principal: user).call

      expect(result.relationships).to be_empty
      expect(result.to_text).to include("No observed foreign-key relationship")
    end

    it "never treats a same-valued non-foreign-key column as a relationship" do
      user = EvidenceUser.create!(id: 5, name: "Ada", email: "ada@example.com")
      document = EvidenceDocument.create!(id: 5, title: "Notes")

      result = described_class.new(resource: document, principal: user).call

      expect(result.relationships).to be_empty
    end

    it "never inspects the primary key column itself as a foreign key" do
      user = EvidenceUser.create!(name: "Ada", email: "ada@example.com")
      document = EvidenceDocument.create!(evidence_user_id: user.id, title: "Notes")
      allow(EvidenceDocument).to receive(:primary_key).and_return("evidence_user_id")

      result = described_class.new(resource: document, principal: user).call

      expect(result.relationships).to be_empty
    end
  end

  describe "Result#to_text" do
    it "matches the plain evidence format: principal, observed status, then related state" do
      principal = Karst::Identity::PrincipalDescriptor.new(model_name: "User", id: 27, display_label: "User #27")
      resource = described_class::ResourceDescriptor.new(model_name: "Document", id: 22)
      relationship = described_class::Relationship.new(column: "user_id", from_model: "Document", from_id: 22,
                                                       to_model: "User", to_id: 27)
      result = described_class::Result.new(principal: principal, resource: resource,
                                           relationships: [relationship].freeze, observed_status: 200,
                                           observed_redirect: nil, limitation: nil)

      expect(result.to_text).to eq(<<~TEXT.strip)
        User #27
        Observed 200

        Related state:
        Document #22
          user_id → User #27
      TEXT
    end

    it "renders a limitation instead of guessing when resolution failed" do
      principal = Karst::Identity::PrincipalDescriptor.new(model_name: "User", id: 27, display_label: "User #27")
      result = described_class::Result.new(principal: principal, resource: nil, relationships: [].freeze,
                                           observed_status: 200, observed_redirect: nil,
                                           limitation: "the route could not be recognized")

      expect(result.to_text).to include("Unavailable: the route could not be recognized")
    end

    it "renders an observed redirect alongside its destination" do
      principal = Karst::Identity::PrincipalDescriptor.new(model_name: "User", id: 3, display_label: "User #3")
      resource = described_class::ResourceDescriptor.new(model_name: "Document", id: 22)
      result = described_class::Result.new(principal: principal, resource: resource, relationships: [].freeze,
                                           observed_status: 302, observed_redirect: "/login", limitation: nil)

      expect(result.to_text).to include("Observed 302 → /login")
    end
  end

  describe ".resolve_resource" do
    def fake_application(recognized: nil, raise_error: false)
      routes = double("routes")
      if raise_error
        allow(routes).to receive(:recognize_path).and_raise(ActionController::RoutingError.new("no route"))
      else
        allow(routes).to receive(:recognize_path).and_return(recognized)
      end
      double("application", routes: routes)
    end

    it "resolves the exact record when the route, controller, and id are all unambiguous" do
      document = EvidenceDocument.create!(title: "Notes")
      app = fake_application(recognized: { controller: "evidence_documents", action: "show", id: document.id.to_s })

      record, limitation = described_class.resolve_resource(path: "/evidence_documents/#{document.id}",
                                                            application: app)

      expect(record).to eq(document)
      expect(limitation).to be_nil
    end

    it "reports a limitation rather than guessing when the route cannot be recognized" do
      app = fake_application(raise_error: true)

      record, limitation = described_class.resolve_resource(path: "/nonexistent", application: app)

      expect(record).to be_nil
      expect(limitation).to match(/could not be recognized/)
    end

    it "reports a limitation when the recognized route has no :id segment" do
      app = fake_application(recognized: { controller: "evidence_documents", action: "index" })

      record, limitation = described_class.resolve_resource(path: "/evidence_documents", application: app)

      expect(record).to be_nil
      expect(limitation).to match(/no :id segment/)
    end

    it "reports a limitation when the controller has no conventional Active Record model" do
      app = fake_application(recognized: { controller: "reports", action: "show", id: "1" })

      record, limitation = described_class.resolve_resource(path: "/reports/1", application: app)

      expect(record).to be_nil
      expect(limitation).to match(/does not map to a loaded Active Record model/)
    end

    it "reports a limitation when no record exists for the recognized id" do
      app = fake_application(recognized: { controller: "evidence_documents", action: "show", id: "999999" })

      record, limitation = described_class.resolve_resource(path: "/evidence_documents/999999", application: app)

      expect(record).to be_nil
      expect(limitation).to match(/no EvidenceDocument record exists/)
    end

    it "reports a limitation when no Rails application is available" do
      record, limitation = described_class.resolve_resource(path: "/evidence_documents/1", application: nil)

      expect(record).to be_nil
      expect(limitation).to match(/no Rails application/)
    end
  end

  describe ".resolve_principal" do
    it "resolves the exact record behind a PrincipalDescriptor" do
      user = EvidenceUser.create!(name: "Ada", email: "ada@example.com")
      descriptor = Karst::Identity::PrincipalDescriptor.new(model_name: "EvidenceUser", id: user.id,
                                                            display_label: "EvidenceUser ##{user.id}")

      record, limitation = described_class.resolve_principal(descriptor)

      expect(record).to eq(user)
      expect(limitation).to be_nil
    end

    it "reports a limitation when the descriptor's model is not a loaded Active Record model" do
      descriptor = Karst::Identity::PrincipalDescriptor.new(model_name: "NotAModel", id: 1,
                                                            display_label: "NotAModel #1")

      record, limitation = described_class.resolve_principal(descriptor)

      expect(record).to be_nil
      expect(limitation).to match(/not a loaded Active Record model/)
    end

    it "reports a limitation when no record exists for the descriptor's id" do
      descriptor = Karst::Identity::PrincipalDescriptor.new(model_name: "EvidenceUser", id: 999_999,
                                                            display_label: "EvidenceUser #999999")

      record, limitation = described_class.resolve_principal(descriptor)

      expect(record).to be_nil
      expect(limitation).to match(/no EvidenceUser record exists/)
    end
  end

  describe ".for_outcome" do
    def outcome_for(descriptor, status: 200, redirect: nil)
      Karst::Access::Outcome.new(principal: descriptor, status: status, redirect: redirect, exception_class: nil,
                                 writes_observed: false, write_count: 0, elapsed_ms: 1.0,
                                 database_rollback_attempted: true)
    end

    it "ties a sweep outcome's principal to the resolved route resource" do
      user = EvidenceUser.create!(name: "Ada", email: "ada@example.com")
      document = EvidenceDocument.create!(evidence_user_id: user.id, title: "Notes")
      descriptor = Karst::Identity::PrincipalDescriptor.new(model_name: "EvidenceUser", id: user.id,
                                                            display_label: "EvidenceUser ##{user.id}")
      routes = double("routes", recognize_path: { controller: "evidence_documents", action: "show",
                                                  id: document.id.to_s })
      app = double("application", routes: routes)

      result = described_class.for_outcome(outcome: outcome_for(descriptor), path: "/evidence_documents/1",
                                           application: app)

      expect(result.limitation).to be_nil
      expect(result.observed_status).to eq(200)
      expect(result.relationships).to contain_exactly(
        have_attributes(column: "evidence_user_id", to_model: "EvidenceUser", to_id: user.id)
      )
    end

    it "carries a limitation forward instead of raising when the resource cannot be resolved" do
      user = EvidenceUser.create!(name: "Ada", email: "ada@example.com")
      descriptor = Karst::Identity::PrincipalDescriptor.new(model_name: "EvidenceUser", id: user.id,
                                                            display_label: "EvidenceUser ##{user.id}")
      routes = double("routes")
      allow(routes).to receive(:recognize_path).and_raise(ActionController::RoutingError.new("no route"))
      app = double("application", routes: routes)

      result = described_class.for_outcome(outcome: outcome_for(descriptor, status: 200), path: "/unknown",
                                           application: app)

      expect(result.resource).to be_nil
      expect(result.limitation).to match(/could not be recognized/)
      expect(result.observed_status).to eq(200)
      expect(result.principal).to eq(descriptor)
    end
  end
end
# rubocop:enable Metrics/BlockLength
