# frozen_string_literal: true

require "rubygems/version"

module Clickwrap
  module IpGeolocation
    # The optional official adapter for the `trackdown` gem.
    #
    #   bundle add trackdown --version ">= 0.4"
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
    # Pinned sources for the mapping (released tag, not a moving branch):
    #   result object -> https://github.com/rameerez/trackdown/blob/v0.4.0/lib/trackdown/location_result.rb
    #   Cloudflare    -> https://github.com/rameerez/trackdown/blob/v0.4.0/lib/trackdown/providers/cloudflare_provider.rb
    #   MaxMind       -> https://github.com/rameerez/trackdown/blob/v0.4.0/lib/trackdown/providers/maxmind_provider.rb
    # Trackdown 0.4.0 closed the provenance gap scoped in
    # https://github.com/rameerez/trackdown/issues/8. This adapter requires that
    # release rather than silently manufacturing the missing facts itself.
    class TrackdownResolver < Resolver
      PROVIDER_NAME = "trackdown"
      MINIMUM_TRACKDOWN_VERSION = Gem::Version.new("0.4.0")

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

      # What Trackdown 0.4 can supply across its providers, used only when the
      # result class cannot be inspected. Cloudflare does not supply an accuracy
      # radius, while MaxMind does; with Trackdown's default :auto provider the
      # adapter can therefore supply it even though any one lookup may not.
      PINNED_CAPABILITIES = %i[
        country region city postal_code latitude_and_longitude timezone continent metro_code
        accuracy_radius_in_kilometers
      ].freeze

      attr_reader :capabilities

      # Whether the host's bundle carries `trackdown` at all. The configuration
      # asks this before adopting the adapter for a policy that enabled
      # IP-geolocation fields without naming a resolver, so the common case —
      # trackdown plus Cloudflare, already bundled — needs no wiring line.
      #
      # It answers the narrow question it is named after and nothing else. An
      # installed release older than 0.4 answers `true` here and then fails in
      # the constructor with the sentence about upgrading, which is far more
      # useful to that host than being told the gem is missing.
      def self.installed?
        require "trackdown" unless defined?(::Trackdown)
        true
      rescue ::LoadError
        false
      end

      # Trust is per request in Trackdown 0.4. A host registers its verifier with
      # Trackdown, Trackdown runs it against the same request that supplied the
      # CDN headers, and this adapter copies the result's explicit trust state.
      # A constructor-wide boolean would overclaim every request after one
      # deployment assertion, so the old experimental option is refused by name.
      def initialize(provider_source: nil, source_verified_by_host: nil)
        super()
        require "trackdown" unless defined?(::Trackdown)
        ensure_supported_trackdown_version!

        unless source_verified_by_host.nil?
          raise ConfigurationError,
                "TrackdownResolver no longer accepts `source_verified_by_host:`. Trackdown " \
                "0.4 verifies source trust per request. Configure " \
                "`Trackdown.configuration.verify_request_came_through_trusted_cloudflare_path_with` " \
                "or the matching CloudFront helper; the resolver will record the result's " \
                "`source_was_verified_by_host?` value."
        end

        @provider_source_fallback = (provider_source || configured_provider_source).to_s
        @capabilities = detect_capabilities.freeze

        freeze
      rescue ::LoadError => error
        raise ConfigurationError,
              "Clickwrap::IpGeolocation::TrackdownResolver needs the `trackdown` gem, which is " \
              "not installed. Run `bundle add trackdown --version \">= 0.4\"` and configure " \
              "it (it needs either a " \
              "MaxMind database or Cloudflare visitor-location headers), or set " \
              "`config.ip_geolocation_resolver = nil` and turn off the IP-geolocation fields " \
              "your policies enable. The underlying load error was: #{error.message}"
      end

      def resolve(ip_address, http_request: nil)
        address = ip_address.to_s.strip
        return unavailable("no_ip_address_to_resolve") if address.empty?

        result = ::Trackdown.locate(address, request: http_request)
        return unavailable("provider_returned_no_result") if result.nil?

        if result.respond_to?(:unavailable?) && result.unavailable?
          return unavailable(
            text(result, :unavailable_reason) || "provider_returned_unavailable",
            result:
          )
        end

        location = build_location(result)

        # Trackdown answers with a result object full of "Unknown" when no
        # provider is configured, when its database has no row for the address,
        # and when a Cloudflare country header says "XX". Once the placeholders
        # are mapped away that is an empty answer, and an empty answer is an
        # unavailable result with a reason on it — not a location whose every
        # field happens to be blank.
        return unavailable("provider_supplied_no_location_fields", result:) unless location.any_data_field?

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

      def unavailable(reason, result: nil)
        Location.unavailable(
          reason:,
          provider_name: provider_name(result),
          provider_source: provider_source(result),
          database_version: database_version(result),
          database_sha256: database_sha256(result),
          estimated: true,
          source_was_verified_by_host: source_was_verified_by_host?(result),
          resolved_at: resolved_at(result)
        )
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
          provider_name: provider_name(result),
          provider_source: provider_source(result),
          database_version: database_version(result),
          database_sha256: database_sha256(result),
          accuracy_radius_in_kilometers: number(result, :accuracy_radius_in_kilometers, :accuracy_radius),
          accuracy_radius_confidence_percentage: number(result, :accuracy_radius_confidence_percentage),
          # Always. No IP geolocation result from any provider is an
          # observation of where anyone was; it is an estimate about an address,
          # and this flag is what keeps a receipt from implying otherwise.
          estimated: true,
          source_was_verified_by_host: source_was_verified_by_host?(result),
          resolved_at: resolved_at(result)
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

      def ensure_supported_trackdown_version!
        version = Gem::Version.new(::Trackdown::VERSION.to_s) if defined?(::Trackdown::VERSION)
        return if version && version >= MINIMUM_TRACKDOWN_VERSION

        installed = version ? version.to_s : "unknown"
        raise ConfigurationError,
              "Clickwrap::IpGeolocation::TrackdownResolver requires trackdown >= " \
              "#{MINIMUM_TRACKDOWN_VERSION}; the loaded version is #{installed}. Run " \
              "`bundle update trackdown` before enabling this resolver. Earlier releases do " \
              "not expose the per-request source trust and provider provenance Clickwrap " \
              "would otherwise have to guess."
      rescue ArgumentError
        raise ConfigurationError,
              "Clickwrap::IpGeolocation::TrackdownResolver could not parse the loaded " \
              "Trackdown::VERSION (#{::Trackdown::VERSION.inspect}). Install trackdown >= " \
              "#{MINIMUM_TRACKDOWN_VERSION} before enabling this resolver."
      end

      def provider_name(result)
        text(result, :provider_name, :provider) || PROVIDER_NAME
      end

      def provider_source(result)
        text(result, :provider_source) || @provider_source_fallback
      end

      # Trackdown exposes MaxMind's exact database build epoch rather than a
      # marketing-style version label. Preserve that integer in a
      # self-describing string: formatting it as a date would throw away the
      # fact that it came from the database metadata and could create timezone
      # ambiguity years later.
      def database_version(result)
        legacy_version = text(result, :database_version, :database_build_version)
        return legacy_version if legacy_version

        epoch = first_value(result, %i[database_build_epoch])
        return nil unless epoch.is_a?(Numeric)

        "database_build_epoch:#{epoch.to_i}"
      end

      def database_sha256(result)
        digest = text(result, :database_sha256, :database_digest)
        return nil if digest.nil?
        return digest if digest.match?(/\Asha256:[0-9a-f]{64}\z/i)
        return "sha256:#{digest.downcase}" if digest.match?(/\A[0-9a-f]{64}\z/i)

        # Do not relabel a provider's non-SHA value as SHA-256. Retaining it is
        # more honest than inventing an algorithm; a host can still inspect the
        # upstream value and a verifier will not mistake it for our digest form.
        digest
      end

      def source_was_verified_by_host?(result)
        result.respond_to?(:source_was_verified_by_host?) &&
          result.source_was_verified_by_host? == true
      rescue StandardError
        false
      end

      def resolved_at(result)
        first_value(result, %i[resolved_at]) || Clickwrap.now
      end

      # Fallback provenance for failures that occur before Trackdown can return
      # a result. Successful Trackdown 0.4 results name the provider that
      # actually answered, including when configuration.provider is `:auto`.
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
