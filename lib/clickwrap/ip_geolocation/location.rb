# frozen_string_literal: true

module Clickwrap
  module IpGeolocation
    # One provider's estimate about ONE IP address, at one moment.
    #
    # Read that sentence literally, because the whole design follows from it.
    # This object never describes where a person was. It describes what a
    # provider's database or edge network said about a network address, with
    # enough provenance attached that someone reading it in four years can tell
    # how much weight it deserves. That is why provider name, source, estimated
    # state, resolution time, and any database or accuracy metadata are members
    # of the same value object as the country code: a country without the
    # provider that guessed it, or coordinates without an accuracy radius, read
    # as far more certain than they are.
    #
    # Every member defaults to nil so a resolver fills in only what it actually
    # has. A resolver must NEVER substitute a placeholder — "Unknown", "XX",
    # "N/A" — for a field it could not determine. A placeholder is
    # indistinguishable from a real provider answer once it is written down, and
    # Clickwrap keeps "we did not collect this", "the provider had no value",
    # "the lookup failed", and "the provider answered" as four different states.
    # nil is the honest answer; `unavailable_reason` is how a resolver explains
    # a failure.
    #
    # `to_h` exists because this is a Data object. It is not a persistence
    # format: the extractor copies out exactly the fields the server-owned
    # policy authorized, one at a time, and a resolver that gains a new field
    # upstream never widens what Clickwrap stores by accident.
    Location = Data.define(
      :country_code,
      :country_name,
      :region_name,
      :region_code,
      :city_name,
      :postal_code,
      :latitude,
      :longitude,
      :timezone,
      :continent_code,
      :metro_code,
      :provider_name,
      :provider_source,
      :database_version,
      :database_sha256,
      :accuracy_radius_in_kilometers,
      :accuracy_radius_confidence_percentage,
      :estimated,
      :source_was_verified_by_host,
      :resolved_at,
      :unavailable_reason
    ) do
      # `estimated` defaults to true and `source_was_verified_by_host` to false
      # because those are the answers that overclaim least. A resolver has to
      # say something deliberate to move either one, and moving
      # `source_was_verified_by_host` requires a host decision about its own
      # network path — never the mere presence of a provider's headers.
      def initialize(country_code: nil, country_name: nil, region_name: nil, region_code: nil,
                     city_name: nil, postal_code: nil, latitude: nil, longitude: nil,
                     timezone: nil, continent_code: nil, metro_code: nil,
                     provider_name: nil, provider_source: nil, database_version: nil,
                     database_sha256: nil, accuracy_radius_in_kilometers: nil,
                     accuracy_radius_confidence_percentage: nil, estimated: true,
                     source_was_verified_by_host: false, resolved_at: nil,
                     unavailable_reason: nil)
        super
      end

      # The answer a resolver returns when it has nothing to report. It still
      # names the provider that was asked, because "MaxMind had no row for this
      # address" and "no resolver was configured at all" are different facts and
      # a receipt has to be able to tell them apart.
      def self.unavailable(reason:, provider_name: nil, **provenance)
        new(unavailable_reason: reason.to_s, provider_name:, **provenance)
      end

      def unavailable? = !unavailable_reason.to_s.strip.empty?

      # An IP-geolocation result is an estimate about an address. This reader
      # reports what the resolver said about its own result rather than
      # hard-coding the answer, but a resolver claiming otherwise still does not
      # turn an observation about a network address into a statement about where
      # anyone was, and the receipt goes on labeling the value provider-reported
      # either way.
      def estimated? = estimated != false

      # True only when the HOST told Clickwrap that this result arrived over a
      # path it has verified. No adapter may set it from the presence of a
      # provider's own headers: headers are attacker-supplied until the
      # deployment proves otherwise.
      def source_was_verified_by_host? = source_was_verified_by_host == true

      # Latitude and longitude are one coupled answer. Half a coordinate is not
      # a result, so nothing downstream is allowed to store one without the
      # other.
      def coordinates? = !latitude.nil? && !longitude.nil?

      def accuracy_radius? = !accuracy_radius_in_kilometers.nil?

      # True when the provider actually reported something about the address, as
      # opposed to handing back a row of blanks. An adapter uses this to turn an
      # empty answer into an explicit unavailable result with a reason, which is
      # the whole point of refusing to write "Unknown" into a name column: an
      # empty result and a real one must never look the same.
      def any_data_field?
        [country_code, country_name, region_name, region_code, city_name, postal_code,
         latitude, longitude, timezone, continent_code, metro_code,
         accuracy_radius_in_kilometers].any? { |value| !value.nil? }
      end
    end
  end
end
