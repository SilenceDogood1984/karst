# frozen_string_literal: true

require "spec_helper"
require "tempfile"
require "karst/web/locality"

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength

RSpec.describe Karst::Web::Locality do
  def locality(environment: {}, osrelease: "Linux", routes: "")
    osrelease_file = Tempfile.new("osrelease")
    route_file = Tempfile.new("route")
    osrelease_file.write(osrelease)
    route_file.write("Iface Destination Gateway Flags RefCnt Use Metric Mask MTU Window IRTT\n#{routes}")
    osrelease_file.close
    route_file.close

    detector = described_class.new(
      environment: environment,
      osrelease_path: osrelease_file.path,
      route_path: route_file.path
    )
    detector.instance_variable_set(:@spec_tempfiles, [osrelease_file, route_file])
    detector
  end

  it "accepts the complete IPv4 loopback range and IPv6 loopback" do
    detector = locality

    expect(detector.local?("127.45.6.7")).to be(true)
    expect(detector.local?("::1")).to be(true)
  end

  it "accepts only the WSL default gateway as a virtualization peer" do
    routes = <<~ROUTES
      eth0 00000000 01001CAC 0003 0 0 0 00000000 0 0 0
      eth0 00001CAC 00000000 0001 0 0 0 00FFFFFF 0 0 0
    ROUTES
    detector = locality(environment: { "WSL_INTEROP" => "/run/WSL/1_interop" }, routes: routes)

    expect(detector.local?("172.28.0.1")).to be(true)
    expect(detector.local?("172.28.0.2")).to be(false)
    expect(detector.local?("10.0.0.1")).to be(false)
    expect(detector.local?("192.168.1.1")).to be(false)
  end

  it "does not accept a default gateway outside WSL" do
    routes = "eth0 00000000 01001CAC 0003 0 0 0 00000000 0 0 0\n"

    expect(locality(routes: routes).local?("172.28.0.1")).to be(false)
  end

  it "rejects malformed and missing addresses" do
    detector = locality

    expect(detector.local?("not-an-address")).to be(false)
    expect(detector.local?(nil)).to be(false)
  end
end

# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
