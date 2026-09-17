# frozen_string_literal: true

require "spec_helper"
require "karst"

RSpec.describe Karst::Access::ObservedEndpoint do
  let(:probe) { double("probe", capture_env: nil) }

  it "hands the running request's own env to the probe before dispatching it" do
    env = { "PATH_INFO" => "/admin" }
    app = ->(received) { [200, {}, [received.equal?(env) ? "same env" : "copy"]] }

    response = described_class.new(app, probe).call(env)

    expect(probe).to have_received(:capture_env).with(env)
    expect(response.last).to eq(["same env"])
  end

  it "stays transparent for everything else the integration session asks the endpoint for" do
    app = double("application", routes: :the_routes, host: "karst-probe.example")
    endpoint = described_class.new(app, probe)

    expect(endpoint).to respond_to(:routes)
    expect(endpoint.routes).to eq(:the_routes)
    expect(endpoint.host).to eq("karst-probe.example")
  end

  it "still raises NoMethodError for something the wrapped endpoint does not have either" do
    endpoint = described_class.new(->(_env) {}, probe)

    expect { endpoint.nonexistent }.to raise_error(NoMethodError)
  end
end
