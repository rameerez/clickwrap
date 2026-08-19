# frozen_string_literal: true

require "test_helper"

class TrackdownResolverTest < ActiveSupport::TestCase
  test "passes the exact request to Trackdown and copies its real provenance" do
    with_fake_trackdown do |trackdown, result_class|
      request = Object.new
      resolved_at = Time.utc(2026, 8, 16, 12, 34, 56)
      result = result_class.new(
        country_code: "ES",
        country_name: "Spain",
        region: "Madrid",
        region_code: "MD",
        city: "Madrid",
        postal_code: "28001",
        latitude: 40.4168,
        longitude: -3.7038,
        timezone: "Europe/Madrid",
        continent: "EU",
        metro_code: "724",
        provider_name: :maxmind,
        provider_source: :maxmind_local_database,
        resolved_at:,
        accuracy_radius_in_kilometers: 20,
        accuracy_radius_confidence_percentage: 67,
        database_build_epoch: 1_735_689_600,
        database_sha256: "A" * 64,
        source_was_verified_by_host: true
      )
      calls = []
      trackdown.define_singleton_method(:locate) do |ip_address, request:|
        calls << [ip_address, request]
        result
      end

      location = Clickwrap::IpGeolocation::TrackdownResolver.new.resolve(
        "203.0.113.7",
        http_request: request
      )

      assert_equal [["203.0.113.7", request]], calls
      assert_equal "ES", location.country_code
      assert_equal "Madrid", location.city_name
      assert_equal "maxmind", location.provider_name
      assert_equal "maxmind_local_database", location.provider_source
      assert_equal "database_build_epoch:1735689600", location.database_version
      assert_equal "sha256:#{"a" * 64}", location.database_sha256
      assert_equal 20, location.accuracy_radius_in_kilometers
      assert_equal 67, location.accuracy_radius_confidence_percentage
      assert location.estimated?
      assert location.source_was_verified_by_host?
      assert_equal resolved_at, location.resolved_at
    end
  end

  test "preserves an unavailable result's reason and provenance" do
    with_fake_trackdown do |trackdown, result_class|
      resolved_at = Time.utc(2026, 8, 16, 13)
      result = result_class.new(
        provider_name: :maxmind,
        provider_source: :maxmind_local_database,
        resolved_at:,
        unavailable_reason: :address_not_found,
        database_build_epoch: 1_735_689_600
      )
      trackdown.define_singleton_method(:locate) { |_ip_address, request:| result }

      location = Clickwrap::IpGeolocation::TrackdownResolver.new.resolve("203.0.113.8")

      assert location.unavailable?
      assert_equal "address_not_found", location.unavailable_reason
      assert_equal "maxmind", location.provider_name
      assert_equal "maxmind_local_database", location.provider_source
      assert_equal "database_build_epoch:1735689600", location.database_version
      assert_equal resolved_at, location.resolved_at
      assert_not location.source_was_verified_by_host?
    end
  end

  test "turns Trackdown placeholders into an explicit unavailable result" do
    with_fake_trackdown do |trackdown, result_class|
      result = result_class.new(
        country_code: "XX",
        country_name: "Unknown",
        city: "N/A",
        provider_name: :cloudflare,
        provider_source: :cloudflare_request_headers,
        source_was_verified_by_host: true
      )
      trackdown.define_singleton_method(:locate) { |_ip_address, request:| result }

      location = Clickwrap::IpGeolocation::TrackdownResolver.new.resolve("203.0.113.9")

      assert location.unavailable?
      assert_equal "provider_supplied_no_location_fields", location.unavailable_reason
      assert_equal "cloudflare", location.provider_name
      assert_equal "cloudflare_request_headers", location.provider_source
      assert location.source_was_verified_by_host?
    end
  end

  test "refuses the old process-wide source trust switch" do
    with_fake_trackdown do
      error = assert_raises(Clickwrap::ConfigurationError) do
        Clickwrap::IpGeolocation::TrackdownResolver.new(source_verified_by_host: true)
      end

      assert_match(/per request/, error.message)
      assert_match(/source_was_verified_by_host/, error.message)
    end
  end

  test "refuses Trackdown releases that cannot report per-request provenance" do
    with_fake_trackdown(version: "0.3.0") do
      error = assert_raises(Clickwrap::ConfigurationError) do
        Clickwrap::IpGeolocation::TrackdownResolver.new
      end

      assert_match(/requires trackdown >= 0\.4\.0/, error.message)
      assert_match(/loaded version is 0\.3\.0/, error.message)
      assert_match(/bundle update trackdown/, error.message)
    end
  end

  private

  def with_fake_trackdown(version: "0.4.0")
    original = Object.const_get(:Trackdown, false) if Object.const_defined?(:Trackdown, false)
    Object.send(:remove_const, :Trackdown) if Object.const_defined?(:Trackdown, false)

    attribute_names = %i[
      country_code country_name region region_code city postal_code latitude longitude
      timezone continent metro_code provider_name provider_source resolved_at unavailable_reason
      accuracy_radius_in_kilometers accuracy_radius_confidence_percentage database_build_epoch
      database_sha256 source_was_verified_by_host
    ]
    result_class = Class.new do
      attr_accessor(*attribute_names)

      def initialize(**attributes)
        attributes.each { |name, value| public_send("#{name}=", value) }
      end

      def unavailable? = !unavailable_reason.nil?
      def source_was_verified_by_host? = source_was_verified_by_host == true
    end

    trackdown = Module.new
    trackdown.const_set(:VERSION, version)
    trackdown.const_set(:LocationResult, result_class)
    configuration = Struct.new(:provider).new(:auto)
    trackdown.define_singleton_method(:configuration) { configuration }
    Object.const_set(:Trackdown, trackdown)

    yield trackdown, result_class
  ensure
    Object.send(:remove_const, :Trackdown) if Object.const_defined?(:Trackdown, false)
    Object.const_set(:Trackdown, original) if original
  end
end
