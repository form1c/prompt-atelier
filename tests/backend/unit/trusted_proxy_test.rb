# frozen_string_literal: true

require_relative '../../test_helper'
require 'services/trusted_proxy'

# Who the caller is (SEC-07, SEC-09).
#
# The application rests two things on this answer: the per-address login limit
# and the address written into every audit entry. Both were defeated by
# believing `X-Forwarded-For` from anybody — which is what the first version
# did, unconditionally and taking the **leftmost** entry, the one part of the
# header a caller writes themselves.
class TrustedProxyTest < PromptAtelier::TestCase
  Subject = PromptAtelier::TrustedProxy

  # --- nobody configured (the delivered state, 18.4) ------------------------

  # The case the defect lived in. With no proxy configured the header is a
  # claim by a stranger, and the socket is the only evidence there is.
  def test_without_configured_proxies_the_header_is_ignored
    assert_equal '203.0.113.9',
                 Subject.client_ip(peer: '203.0.113.9', forwarded: '198.51.100.1', trusted: [])
  end

  def test_a_missing_configuration_is_the_same_as_an_empty_one
    assert_equal '203.0.113.9',
                 Subject.client_ip(peer: '203.0.113.9', forwarded: '198.51.100.1', trusted: nil)
  end

  # --- a proxy of one's own -------------------------------------------------

  # The chain is read from the right. A proxy appends what it saw; everything
  # further left came from the caller. `198.51.100.1` here is the invention —
  # and it is exactly what the broken version returned.
  def test_behind_a_trusted_proxy_the_last_hop_counts_not_the_first
    address = Subject.client_ip(peer: '10.0.0.7',
                                forwarded: '198.51.100.1, 203.0.113.9',
                                trusted: ['10.0.0.0/8'])

    assert_equal '203.0.113.9', address
  end

  def test_a_chain_of_several_proxies_of_ones_own_is_skipped_over
    address = Subject.client_ip(peer: '10.0.0.7',
                                forwarded: '198.51.100.1, 203.0.113.9, 10.0.0.3',
                                trusted: ['10.0.0.0/8'])

    assert_equal '203.0.113.9', address, 'the last hop that is not ours'
  end

  # Nothing in the header is about a client then, and inventing one would be
  # worse than naming the machine that really called.
  def test_when_every_hop_is_ours_the_peer_is_the_answer
    address = Subject.client_ip(peer: '10.0.0.7', forwarded: '10.0.0.3, 10.0.0.4',
                                trusted: ['10.0.0.0/8'])

    assert_equal '10.0.0.7', address
  end

  def test_a_trusted_proxy_without_a_header_stays_itself
    assert_equal '10.0.0.7',
                 Subject.client_ip(peer: '10.0.0.7', forwarded: nil, trusted: ['10.0.0.0/8'])
  end

  # A configured block must not quietly cover addresses outside it. Chosen so
  # that a mutation widening the mask (10.0.0.0/8 for 10.0.0.0/24) changes the
  # answer.
  def test_a_block_covers_what_it_names_and_nothing_beside_it
    inside  = Subject.client_ip(peer: '10.0.0.5', forwarded: '203.0.113.9',
                                trusted: ['10.0.0.0/24'])
    outside = Subject.client_ip(peer: '10.0.1.5', forwarded: '203.0.113.9',
                                trusted: ['10.0.0.0/24'])

    assert_equal '203.0.113.9', inside
    assert_equal '10.0.1.5', outside, 'a neighbouring block is not the proxy'
  end

  def test_an_address_of_a_different_family_does_not_match_a_block
    address = Subject.client_ip(peer: '::1', forwarded: '203.0.113.9',
                                trusted: ['10.0.0.0/8'])

    assert_equal '::1', address
  end

  def test_ipv6_works_as_well
    address = Subject.client_ip(peer: '2001:db8::1', forwarded: '198.51.100.1, 203.0.113.9',
                                trusted: ['2001:db8::/32'])

    assert_equal '203.0.113.9', address
  end

  # --- robustness -----------------------------------------------------------

  # Startup refuses an unparseable block (18.4), so this should not happen. If
  # it does, it must not take a request down.
  def test_an_unusable_entry_is_passed_over_rather_than_raising
    address = Subject.client_ip(peer: '10.0.0.7', forwarded: '203.0.113.9',
                                trusted: ['nonsense', '10.0.0.0/8'])

    assert_equal '203.0.113.9', address
  end

  def test_rubbish_in_the_header_does_not_become_an_address
    address = Subject.client_ip(peer: '10.0.0.7', forwarded: 'unknown, 203.0.113.9',
                                trusted: ['10.0.0.0/8'])

    assert_equal '203.0.113.9', address, 'the rightmost usable hop'
  end

  def test_empty_entries_in_the_chain_are_dropped
    address = Subject.client_ip(peer: '10.0.0.7', forwarded: '203.0.113.9, , 10.0.0.3',
                                trusted: ['10.0.0.0/8'])

    assert_equal '203.0.113.9', address
  end

  # --- the same boundary for the protocol header (SEC-03, SEC-14) -----------

  def test_the_protocol_header_is_believed_from_a_proxy_only
    refute Subject.trusted_peer?('203.0.113.9', ['10.0.0.0/8'])
    assert Subject.trusted_peer?('10.0.0.7', ['10.0.0.0/8'])
    refute Subject.trusted_peer?('10.0.0.7', []), 'nobody configured, nobody believed'
  end

  # --- what the configuration check asks (18.4) -----------------------------

  def test_valid_entry_accepts_addresses_and_blocks_and_refuses_the_rest
    assert Subject.valid_entry?('127.0.0.1')
    assert Subject.valid_entry?('10.0.0.0/8')
    assert Subject.valid_entry?('2001:db8::/32')
    refute Subject.valid_entry?('10.0.0.0/99')
    refute Subject.valid_entry?('kein-netz')
    refute Subject.valid_entry?('')
  end
end
