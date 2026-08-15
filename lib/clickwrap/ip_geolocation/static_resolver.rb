# frozen_string_literal: true

module Clickwrap
  module IpGeolocation
    # A resolver that answers from a fixed table of addresses.
    #
    #   Clickwrap.config.ip_geolocation_resolver =
    #     Clickwrap::IpGeolocation::StaticResolver.new(
    #       "203.0.113.10" => {
    #         country_code: "ES",
    #         country_name: "Spain",
    #         city_name: "Madrid",
    #         latitude: 40.4168,
    #         longitude: -3.7038,
    #         accuracy_radius_in_kilometers: 20,
    #         provider_source: "test_city_database",
    #         database_version: "2026-08-01"
    #       }
    #     )
    #
    # This is what the gem's own tests run against, and it is the right resolver
    # for a host's test and development environments too. A real provider makes
    # request-evidence tests non-deterministic in the one place where
    # determinism matters most: an assertion about exactly which fields a policy
    # stored has to fail because the ALLOWLIST changed, never because a database
    # was rebuilt or an address was reassigned between two runs.
    #
    # Values may be given as attribute hashes or as Location objects. An address
    # that is not in the table resolves to an explicit unavailable result — not
    # to a blank one, and not to a plausible-looking default, because a fixture
    # that quietly invents a country is a test that proves nothing.
    class StaticResolver < Resolver
      PROVIDER_NAME = "static_ip_geolocation_fixture"
      NO_FIXTURE_REASON = "no_fixture_for_this_ip_address"

      # The fixture table can be written straight into the call, which is how it
      # reads best in a test:
      #
      #   StaticResolver.new("203.0.113.10" => { country_code: "ES" })
      #
      # Ruby hands a trailing bare hash over as keyword arguments, so those
      # addresses arrive in `fixtures` and are merged with the positional form
      # below. Wrap the table in braces when you also pass an option:
      #
      #   StaticResolver.new({ "203.0.113.10" => { ... } }, capabilities: %i[country])
      #
      # `capabilities:` is worth setting deliberately. It models what a provider
      # can supply AT ALL, which is a different fact from what it happened to
      # return for one address: a Cloudflare visitor-header set supplies no
      # accuracy radius ever, while a MaxMind city database supplies one but may
      # have no value for a particular address. Clickwrap explains an empty
      # result differently in those two cases, so a fixture that wants to
      # exercise the Cloudflare shape should say
      # `capabilities: %i[country region city latitude_and_longitude timezone]`.
      def initialize(locations_by_ip_address = {}, capabilities: nil, provider_name: PROVIDER_NAME,
                     **fixtures)
        super()
        # Written as an explicit keyword, the table lands in `fixtures` like any
        # other trailing hash. Take it back out so both spellings mean the same
        # thing, rather than one of them quietly building a table with a single
        # nonsense entry named after the parameter.
        declared = fixtures.delete(:locations_by_ip_address).to_h

        @provider_name = provider_name.to_s
        @locations_by_ip_address = build_table(locations_by_ip_address.to_h.merge(declared).merge(fixtures)).freeze
        @capabilities = normalize_capabilities(capabilities).freeze

        freeze
      end

      attr_reader :capabilities

      def resolve(ip_address)
        @locations_by_ip_address.fetch(ip_address.to_s.strip) do
          Location.unavailable(reason: NO_FIXTURE_REASON, provider_name: @provider_name)
        end
      end

      private

      def build_table(declaration)
        declaration.to_h { |ip_address, location| [ip_address.to_s.strip, build_location(location)] }
      end

      # A fixture written as a hash still comes back as a fully formed result:
      # provider name and resolution time are filled in when the hash omits
      # them, because a stored IP-geolocation value without its provenance is
      # exactly what the extractor refuses to write, and a fixture that could
      # not survive that rule would be testing the wrong thing.
      def build_location(location)
        return location if location.is_a?(Location)

        attributes = location.to_h.transform_keys(&:to_sym)
        attributes[:provider_name] ||= @provider_name
        attributes[:resolved_at] ||= Clickwrap.now

        Location.new(**attributes)
      end

      def normalize_capabilities(declared)
        return Vocabulary::IP_GEOLOCATION_DATA_FIELDS.map(&:to_sym) if declared.nil?

        Array(declared).map { |field| field.to_s.to_sym }
      end
    end
  end
end
