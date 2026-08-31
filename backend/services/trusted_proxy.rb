# frozen_string_literal: true

require 'ipaddr'

module PromptAtelier
  # Who is actually calling (SEC-07, SEC-09).
  #
  # `X-Forwarded-For` is written by whoever sends the request. It is evidence
  # only when the sender is a proxy we put there ourselves; from anybody else
  # it is a claim about a third party. Two things in this application rest on
  # the caller's address — the per-address login limit and the address written
  # into the audit log — and both were defeated by believing the header
  # unconditionally: a different value per request left the limit untouched,
  # and any address at all could be dropped into the log.
  #
  # The rule is therefore: the header counts only when the **immediate peer**
  # (`REMOTE_ADDR`) is one of the configured proxies. Delivered configuration
  # lists none, which is right for the direct operation of 18.4 and for the
  # portable mode.
  module TrustedProxy
    module_function

    # The caller's address.
    #
    # +peer+      REMOTE_ADDR — the address the socket really came from
    # +forwarded+ raw X-Forwarded-For header, may be nil
    # +trusted+   configured proxies, addresses or CIDR blocks
    #
    # The chain is read from the **right**, not from the left. A proxy appends
    # the address it saw; anything further left was supplied by the caller and
    # may be invented. `1.2.3.4, <real client>` is what an attacker produces by
    # sending a header of their own, and the leftmost entry — which the first
    # version of this code took — is precisely the invented one.
    def client_ip(peer:, forwarded: nil, trusted: nil)
      proxies = networks(trusted)
      return peer if proxies.empty?
      return peer unless trusted?(peer, proxies)

      chain = String(forwarded).split(',').map(&:strip).reject(&:empty?)

      # Skip further proxies of our own, then take what they saw. If every hop
      # is one of ours the header carries nothing about a client, and the peer
      # is the most truthful answer left.
      chain.reverse.find { |hop| !trusted?(hop, proxies) } || peer
    end

    # Whether the header of a request from +peer+ may be believed at all. Used
    # for `X-Forwarded-Proto` as well, which decides the `Secure` attribute and
    # the HTTPS redirect (SEC-03, SEC-14) and is no more trustworthy.
    def trusted_peer?(peer, trusted)
      proxies = networks(trusted)
      return false if proxies.empty?

      trusted?(peer, proxies)
    end

    # Invalid entries are rejected at startup (18.4), so they should not reach
    # this point — but a nil configuration does, in tests and in scripts, and
    # an unparseable value must not take the process down at request time.
    def networks(trusted)
      Array(trusted).filter_map do |entry|
        IPAddr.new(entry.to_s.strip)
      rescue IPAddr::Error
        nil
      end
    end

    def trusted?(address, proxies)
      candidate = IPAddr.new(address.to_s.strip)
      proxies.any? { |net| net.family == candidate.family && net.include?(candidate) }
    rescue IPAddr::Error
      false
    end

    # Used by the configuration check so that a mistyped block aborts startup
    # with the key named, rather than silently trusting nobody (18.4).
    def valid_entry?(entry)
      IPAddr.new(entry.to_s.strip)
      true
    rescue IPAddr::Error
      false
    end
  end
end
