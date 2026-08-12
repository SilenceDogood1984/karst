# frozen_string_literal: true

require "spec_helper"
require "karst"
require "karst/web/populations_panel"

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Web::PopulationsPanel do
  def entry(model_name, method_name)
    Karst::Access::PopulationApprovals::Entry.new(model_name: model_name, method_name: method_name)
  end

  def render(**kwargs)
    described_class.render(**kwargs).last.join
  end

  it "serves a script-free, non-cacheable advanced management page" do
    status, headers, body = described_class.render

    expect(status).to eq(200)
    expect(headers).to include("cache-control" => "no-store", "x-robots-tag" => "noindex, nofollow")
    expect(headers["content-security-policy"]).to include("default-src 'none'")
    expect(body.join).to include("Advanced local-state management")
    expect(body.join).not_to include("<script", "Approve selected", "Search groups")
  end

  it "lists only existing approvals with individual revocation actions" do
    body = render(approved: [entry("User", "system_admins"), entry("User", "auditors")])

    expect(body).to include("User.system_admins", "User.auditors")
    expect(body.scan('value="revoke_population"').size).to eq(2)
    expect(body).to include('value="User::system_admins"', "Revoke")
  end

  it "makes the empty state explicit and offers no approval workflow" do
    body = render

    expect(body).to include("No population approvals are stored.")
    expect(body).not_to include("type=\"checkbox\"", "Candidate groups")
  end

  it "marks both kinds of stale approval without hiding either" do
    first = entry("User", "system_admins")
    second = entry("Subscription", "renewable")
    body = render(approved: [first, second], stale: [[first, :not_discovered], [second, :no_principal_source]])

    expect(body).to include("no longer a discovered scope on this model — not used",
                            "not part of a configured user source — not used")
  end

  it "reports successful revocation and local-state errors honestly" do
    expect(render(revoked: true)).to include("Approval revoked.")
    expect(render(storage_error: "approval file is broken")).to include('role="alert"', "approval file is broken")
  end

  it "escapes stored labels, errors, and paths" do
    hostile = entry("User<script>", "admins</code>")
    body = render(approved: [hostile], storage_error: "<script>error</script>", storage_path: "tmp/<bad>")

    expect(body).not_to include("User<script>", "<script>error</script>", "tmp/<bad>")
    expect(body).to include(CGI.escapeHTML(hostile.display_label))
  end
end
# rubocop:enable Metrics/BlockLength
