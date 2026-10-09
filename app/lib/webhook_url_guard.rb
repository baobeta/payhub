# typed: true
# frozen_string_literal: true

require "resolv"
require "ipaddr"

# Merchants choose their webhook URL, and we POST to it from inside our
# network. Without this check a merchant could aim deliveries at the cloud
# metadata service or an internal host and read the answers in the delivery
# log (SSRF). Checked when the URL is saved AND right before each delivery,
# so a hostname re-pointed later (DNS rebinding) is caught too.
module WebhookUrlGuard
  BLOCKED = %w[
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12
    192.0.0.0/24 192.168.0.0/16 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4
    ::/128 ::1/128 fc00::/7 fe80::/10 ff00::/8
  ].map { |cidr| IPAddr.new(cidr) }.freeze

  # Local development posts to receivers on localhost or compose services.
  def self.allow_private? = !Rails.env.production?

  # nil when the URL is safe to POST to, else a reason fit to show the merchant.
  def self.problem(url, allow_private: allow_private?)
    uri = URI.parse(url)
    host = uri.host
    return "must be an http(s) URL" unless %w[http https].include?(uri.scheme) && host.present?
    return "must use https" if !allow_private && uri.scheme != "https"
    return nil if allow_private

    addresses = literal_ip?(host) ? [host] : Resolv.getaddresses(host)
    return "host does not resolve" if addresses.empty?

    blocked = addresses.find { |a| private_address?(a) }
    blocked ? "resolves to a private or reserved address (#{blocked})" : nil
  rescue URI::InvalidURIError, IPAddr::InvalidAddressError
    "is not a valid URL"
  end

  def self.private_address?(address)
    ip = IPAddr.new(address.delete("[]"))
    ip = ip.native if ip.ipv4_mapped?
    BLOCKED.any? { |range| range.family == ip.family && range.include?(ip) }
  end

  def self.literal_ip?(host)
    IPAddr.new(host.delete("[]"))
    true
  rescue IPAddr::InvalidAddressError
    false
  end
end
