# frozen_string_literal: true

require "ipaddr"

module Karst
  module Web
    # Determines whether a Rack peer is local without consulting proxy headers.
    # WSL's NAT makes a Windows browser appear as the Linux VM's default gateway,
    # so that one address is accepted when the process is verifiably running in
    # WSL. Other private-network peers remain untrusted.
    class Locality
      LOOPBACK_RANGES = [IPAddr.new("127.0.0.0/8"), IPAddr.new("::1")].freeze
      private_constant :LOOPBACK_RANGES

      def initialize(environment: ENV, osrelease_path: "/proc/sys/kernel/osrelease", route_path: "/proc/net/route")
        @environment = environment
        @osrelease_path = osrelease_path
        @route_path = route_path
      end

      def local?(remote_address)
        address = IPAddr.new(remote_address.to_s)
        loopback?(address) || wsl_gateway == address
      rescue IPAddr::Error
        false
      end

      private

      def loopback?(address)
        LOOPBACK_RANGES.any? { |range| range.include?(address) }
      end

      def wsl_gateway
        return unless wsl?

        gateway_address(default_gateway_hex)
      rescue Errno::ENOENT, Errno::EACCES, IPAddr::Error
        nil
      end

      def default_gateway_hex
        route = File.foreach(@route_path).drop(1).find do |line|
          fields = line.split
          fields[1] == "00000000" && fields[3].to_i(16).anybits?(0x2)
        end
        route&.split&.fetch(2, nil)
      end

      def gateway_address(hex)
        return unless hex&.match?(/\A[0-9A-Fa-f]{8}\z/)

        IPAddr.new([hex].pack("H*").reverse.unpack("C4").join("."))
      end

      def wsl?
        @environment.key?("WSL_INTEROP") || @environment.key?("WSL_DISTRO_NAME") ||
          File.read(@osrelease_path).match?(/microsoft|wsl/i)
      rescue Errno::ENOENT, Errno::EACCES
        false
      end
    end
  end
end
