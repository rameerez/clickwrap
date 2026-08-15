# frozen_string_literal: true

module Clickwrap
  module IpGeolocation
    # The resolver Clickwrap uses when the host configured none.
    #
    # It exists so that "no IP geolocation provider is installed" is an ordinary
    # answer with a reason on it, rather than a branch that has to be handled
    # separately everywhere. Every capture path runs the same code; a host with
    # no geolocation gem gets `ip_geolocation_unavailable_reason` set to
    # `no_resolver_configured`, which is a true statement about the application
    # and reads correctly on a receipt years later.
    #
    # That also means the entire request-evidence feature — policies, field
    # allowlists, retention, receipts, disposal — is testable and reviewable
    # without a provider account, a database download, or a network call.
    #
    # A policy that authorizes IP-geolocation fields while no resolver is
    # configured is caught earlier, by `Configuration#validate!`, with a
    # sentence saying so. This resolver is the safety net under that check, not
    # a way to pretend the configuration is fine.
    class NullResolver < Resolver
      REASON = "no_resolver_configured"

      def resolve(_ip_address)
        Location.unavailable(reason: REASON)
      end

      # Nothing. Not "everything but it always fails" — a host reading
      # `capabilities` is asking what this resolver could ever supply, and the
      # honest answer is no field at all.
      def capabilities = [].freeze
    end
  end
end
