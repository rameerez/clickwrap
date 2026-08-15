# frozen_string_literal: true

module Clickwrap
  module IpGeolocation
    # The optional official adapter for the `trackdown` gem.
    #
    #   bundle add trackdown
    #
    #   Clickwrap.configure do |config|
    #     config.ip_geolocation_resolver = Clickwrap::IpGeolocation::TrackdownResolver.new
    #   end
    #
    # `trackdown` is NOT a dependency of this gem and must never become one. It
    # is required lazily, inside the constructor, so that a host who never names
    # this class never loads it — and so that a host who does name it without
    # installing it gets one sentence telling them what to do, at the line in
    # their initializer that asked for it, instead of a NameError somewhere in
    # the middle of a capture.
    #
    # Two rules shape the mapping below, and both exist because this adapter
    # sits between a general-purpose geolocation gem and an evidence record that
    # has to still be readable and honest in several years.
    #
    # ONE: every field is read through `respond_to?`. Trackdown's result object
    # has gained fields across releases and will gain more; a `NoMethodError`
    # during a capture would roll back the protected action for a field the
    # policy may not even have authorized. Reading defensively means a newer
    # Trackdown supplying an accuracy radius is picked up here with no change,
    # and an older one simply reports nil.
    #
    # TWO: `to_h` is never persisted. Trackdown's `to_h` includes `country_info`
    # — the whole ISO3166 country record — and a general gem is right to offer
    # it. Copying it into evidence would store data no policy authorized and no
    # receipt could explain. Clickwrap copies named fields, one at a time, and
    # the extractor then keeps only the subset the server-owned policy allowed.
    #
    # Pinned source for the mapping (immutable commit, not a moving branch):
    #   result object -> https://github.com/rameerez/trackdown/blob/41587b1413cd3743a86b115806812216bc45250e/lib/trackdown/location_result.rb#L5-L55
    #   Cloudflare    -> https://github.com/rameerez/trackdown/blob/41587b1413cd3743a86b115806812216bc45250e/lib/trackdown/providers/cloudflare_provider.rb#L29-L64
    # The provenance fields Clickwrap would like Trackdown to expose upstream —
    # resolution time, database build version and digest, MaxMind accuracy
    # radius, an explicit estimated flag, and host-verified source state — are
    # scoped in https://github.com/rameerez/trackdown/issues/8.
    class TrackdownResolver < Resolver
      PROVIDER_NAME = "trackdown"

      # Trackdown returns the string "Unknown" for a country or city it could
      # not determine, and Cloudflare's own "no country" code is "XX"
      # (pinned provider source above). Neither is a place. Written into a
      # receipt they would be indistinguishable from a country a provider
      # actually reported, so they are mapped back to nil and the extractor
      # records "the provider supplied no authorized field" instead. This is the
      # single most important line in this file.
      PLACEHOLDER_VALUES = ["unknown", "n/a", "xx", "-"].freeze

      # What Trackdown could supply at all, by Clickwrap field name. Read
      # dynamically from the installed result object where possible, so a
      # Trackdown release that adds accuracy radius starts reporting the
      # capability without an edit here.
      FIELD_READERS = {
        country: %i[country_code country_name],
        region: %i[region region_name region_code],
        city: %i[city city_name],
        postal_code: %i[postal_code],
        latitude_and_longitude: %i[latitude longitude],
        timezone: %i[timezone time_zone],
        continent: %i[continent continent_code],
        metro_code: %i[metro_code],
        accuracy_radius_in_kilometers: %i[accuracy_radius accuracy_radius_in_kilometers]
      }.freeze

      # What the pinned Trackdown release supplies, used only when the result
      # class cannot be inspected. It deliberately omits the accuracy radius:
      # neither the MaxMind nor the Cloudflare provider exposes one at that
      # commit, and a capability claimed but never delivered would turn "this
      # provider cannot supply a radius" into "this address had no radius".
      PINNED_CAPABILITIES = %i[
        country region city postal_code latitude_and_longitude timezone continent metro_code
      ].freeze

      attr_reader :capabilities

      # `source_verified_by_host:` is the ONLY way this adapter will ever mark a
      # result as arriving over a verified path, and it is false by default.
      #
      # Say it plainly, because it is the mistake this parameter exists to
      # prevent: the presence of Cloudflare's `CF-*` headers is not proof of a
      # trusted origin path. Those headers are ordinary request headers, and
      # anyone who can reach the origin server directly can send them. Passing
      # true here is the host stating that its deployment blocks direct origin
      # access, or that trusted infrastructure strips and re-sets those headers
      # before the application sees them. Clickwrap cannot check that claim; it
      # records who made it.
      def initialize(source_verified_by_host: false, provider_source: nil)
        super()
        require "trackdown" unless defined?(::Trackdown)

        @source_verified_by_host = source_verified_by_host == true
        @provider_source = (provider_source || configured_provider_source).to_s
        @capabilities = detect_capabilities.freeze

        freeze
      rescue ::LoadError => error
        raise ConfigurationError,
              "Clickwrap::IpGeolocation::TrackdownResolver needs the `trackdown` gem, which is " \
              "not installed. Run `bundle add trackdown` and configure it (it needs either a " \
              "MaxMind database or Cloudflare visitor-location headers), or set " \
              "`config.ip_geolocation_resolver = nil` and turn off the IP-geolocation fields " \
              "your policies enable. The underlying load error was: #{error.message}"
      end

      def resolve(ip_address)
        address = ip_address.to_s.strip
        return unavailable("no_ip_address_to_resolve") if address.empty?

        result = ::Trackdown.locate(address)
        return unavailable("provider_returned_no_result") if result.nil?

        location = build_location(result)

        # Trackdown answers with a result object full of "Unknown" when no
        # provider is configured, when its database has no row for the address,
        # and when a Cloudflare country header says "XX". Once the placeholders
        # are mapped away that is an empty answer, and an empty answer is an
        # unavailable result with a reason on it — not a location whose every
        # field happens to be blank.
        return unavailable("provider_supplied_no_location_fields") unless location.any_data_field?

        location
      rescue StandardError => error
        # Trackdown raises for ordinary conditions — a private or loopback
        # address in development, a missing MaxMind database, a lookup timeout.
        # None of those should abort a capture by itself: the policy decides
        # whether unavailable IP geolocation is fatal. The reason carries the
        # error CLASS and never the message, because a provider message can
        # quote the IP address and this string is written to a column that a
        # redacted receipt is allowed to show.
        unavailable("trackdown_raised_#{error.class}")
      end

      private

      def unavailable(reason)
        Location.unavailable(reason: reason, provider_name: PROVIDER_NAME)
      end

      def build_location(result)
        Location.new(
          country_code: text(result, :country_code),
          country_name: text(result, :country_name),
          region_name: text(result, :region, :region_name),
          region_code: text(result, :region_code),
          city_name: text(result, :city, :city_name),
          postal_code: text(result, :postal_code),
          latitude: number(result, :latitude),
          longitude: number(result, :longitude),
          timezone: text(result, :timezone, :time_zone),
          # Both Trackdown providers put a two-letter code in `continent`
          # (MaxMind's `continent.code`, Cloudflare's `CF-IPContinent`), which
          # is why it maps to the continent CODE column rather than a name.
          continent_code: text(result, :continent, :continent_code),
          metro_code: text(result, :metro_code),
          provider_name: PROVIDER_NAME,
          provider_source: @provider_source,
          database_version: text(result, :database_version, :database_build_version),
          database_sha256: text(result, :database_sha256, :database_digest),
          accuracy_radius_in_kilometers: number(result, :accuracy_radius_in_kilometers, :accuracy_radius),
          accuracy_radius_confidence_percentage: number(result, :accuracy_radius_confidence_percentage),
          # Always. No IP geolocation result from any provider is an
          # observation of where anyone was; it is an estimate about an address,
          # and this flag is what keeps a receipt from implying otherwise.
          estimated: true,
          source_was_verified_by_host: @source_verified_by_host,
          resolved_at: Clickwrap.now
        )
      end

      # Reads the first reader the result object actually has. Returns nil for a
      # missing reader, a blank value, or one of Trackdown's placeholders — a
      # missing field must be indistinguishable from nothing, never from an
      # answer.
      def text(result, *readers)
        value = first_value(result, readers)
        return nil if value.nil?

        string = value.to_s.strip
        return nil if string.empty?
        return nil if PLACEHOLDER_VALUES.include?(string.downcase)

        string
      end

      def number(result, *readers)
        value = first_value(result, readers)
        return nil if value.nil?
        return nil if value.to_s.strip.empty?

        value
      end

      def first_value(result, readers)
        readers.each do |reader|
          next unless result.respond_to?(reader)

          value = result.public_send(reader)
          return value unless value.nil?
        rescue StandardError
          # A reader that raises is treated as a reader the provider does not
          # have. One awkward field must not cost the whole result.
          next
        end

        nil
      end

      # Which Trackdown provider was asked. Trackdown does not report which one
      # actually answered under its `:auto` setting, so this records the
      # configured selection rather than claiming to know the answering source.
      def configured_provider_source
        return "unspecified" unless ::Trackdown.respond_to?(:configuration)

        ::Trackdown.configuration.provider.to_s
      rescue StandardError
        "unspecified"
      end

      def detect_capabilities
        result_class = trackdown_result_class
        return PINNED_CAPABILITIES.dup if result_class.nil?

        supplied = FIELD_READERS.select do |_field, readers|
          readers.any? { |reader| result_class.method_defined?(reader) }
        end

        supplied.keys
      end

      def trackdown_result_class
        defined?(::Trackdown::LocationResult) ? ::Trackdown::LocationResult : nil
      end
    end
  end
end
