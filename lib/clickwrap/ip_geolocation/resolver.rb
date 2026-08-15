# frozen_string_literal: true

module Clickwrap
  # IP geolocation adapters.
  #
  # Clickwrap has no geolocation dependency and never will. What it has is this
  # narrow contract, one no-op default that lets the whole feature be exercised
  # without any provider, a deterministic fixture resolver for tests, and one
  # optional official adapter for `trackdown`. A host that wants a different
  # provider writes forty lines against the contract below and configures it.
  module IpGeolocation
    # The adapter contract every IP geolocation resolver implements.
    #
    #   class MyResolver < Clickwrap::IpGeolocation::Resolver
    #     def resolve(ip_address)
    #       row = MyProvider.lookup(ip_address) or
    #         return Location.unavailable(reason: "provider_had_no_row", provider_name: "my_provider")
    #
    #       Location.new(
    #         country_code: row.country_iso,
    #         provider_name: "my_provider",
    #         provider_source: "my_provider_city_database",
    #         database_version: row.database_build,
    #         estimated: true,
    #         resolved_at: Clickwrap.now
    #       )
    #     end
    #
    #     def capabilities = %i[country]
    #   end
    #
    # Subclassing is optional — `Clickwrap.config.ip_geolocation_resolver`
    # accepts anything that responds to `#resolve` — but inheriting documents
    # the intent and gives you the contract's own error messages when a method
    # is missing.
    #
    # Three obligations that are easy to miss, and that the rest of the gem
    # depends on:
    #
    #   1. Return nil ONLY for a field the provider genuinely did not supply.
    #      Never a placeholder string. "Unknown" written into a country name is
    #      indistinguishable from a country a provider actually reported, and
    #      collapsing those two states is exactly what a receipt must not do.
    #
    #   2. Say who answered. Set `provider_name`, and `provider_source` when the
    #      provider has more than one source (a local city database and an edge
    #      network are not the same evidence). Attach `database_version`,
    #      `database_sha256`, `accuracy_radius_in_kilometers`, and
    #      `accuracy_radius_confidence_percentage` whenever the provider gives
    #      them: the extractor stores that provenance with any coordinate it
    #      keeps, because coordinates without uncertainty overclaim.
    #
    #   3. Never infer trust from a provider's own headers. Leave
    #      `source_was_verified_by_host` false unless the HOST has explicitly
    #      told the adapter that its deployment blocks direct origin access or
    #      sanitizes those headers. A `CF-*` header is a client-supplied string
    #      until the deployment proves otherwise.
    #
    # A resolver is called SYNCHRONOUSLY, before the evidence and domain
    # transaction opens, so it must be fast and must not raise for ordinary
    # conditions. A private, loopback, or reserved address is an ordinary
    # condition: return `Location.unavailable(...)`, do not raise. Clickwrap
    # rescues a raising resolver and records the failure rather than losing it,
    # but a reason string you chose is better evidence than an exception class
    # Clickwrap had to guess a name from.
    class Resolver
      # Estimate a location for one observed IP address.
      #
      # Returns a Location — populated, or `Location.unavailable(reason:,
      # provider_name:)`. Returning nil is permitted for an adapter that has
      # nothing at all to say; Clickwrap records it as `resolver_returned_no_result`,
      # which is a less useful receipt than a reason you wrote yourself.
      def resolve(ip_address)
        raise NotImplementedError,
              "#{self.class} must implement #resolve(ip_address) and return a " \
              "Clickwrap::IpGeolocation::Location (or nil). See the contract in " \
              "lib/clickwrap/ip_geolocation/resolver.rb."
      end

      # Which of `Clickwrap::Vocabulary::IP_GEOLOCATION_DATA_FIELDS` this
      # resolver can supply at all, as symbols.
      #
      # This is a statement about the adapter and its provider, not about any
      # one lookup: a Cloudflare header set structurally supplies no accuracy
      # radius, which is a different fact from a MaxMind database that supplies
      # one but had no value for this address. Clickwrap uses the difference to
      # explain an empty result honestly, and `clickwrap:doctor` uses it to tell
      # a host that a policy authorizes a field its resolver can never fill.
      def capabilities
        raise NotImplementedError,
              "#{self.class} must implement #capabilities and return the subset of " \
              "Clickwrap::Vocabulary::IP_GEOLOCATION_DATA_FIELDS it can supply, as symbols. " \
              "Return [] if it can supply none."
      end
    end
  end
end
