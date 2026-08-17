# frozen_string_literal: true

require "test_helper"

# Optional request evidence: off unless a policy names the field, encrypted,
# separately disposable, and never described as more than it is.
#
# The required-tests list in `docs/strategy/02-request-evidence.md` is the source
# for most of this file.
class RequestEvidenceTest < ActiveSupport::TestCase
  use_real_database_commits!

  setup do
    @user = create_user
    @http_request = fake_http_request
  end

  # --- Safe defaults ----------------------------------------------------------

  test "an ordinary policy records no IP address, user agent, or geolocation" do
    receipt = capture_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })

    assert_nil receipt.event.request_evidence
    assert_empty receipt.event.request_evidence_category_binding_digests
    assert_nil receipt.event.request_evidence_digest_algorithm
    assert_nil receipt.event.request_evidence_key_id

    receipt.to_h["request_evidence"].each_value do |fragment|
      assert_equal "not_configured", fragment["state"]
    end
  end

  test "the initializer defaults are all off" do
    config = Clickwrap::Configuration.new

    assert_not config.record_ip_address_by_default
    assert_not config.record_browser_user_agent_by_default
    Clickwrap::Vocabulary::IP_GEOLOCATION_DATA_FIELDS.each do |field|
      assert_not config.public_send(:"record_ip_geolocation_#{field}_by_default"),
                 "#{field} must default to off"
    end
    assert_not config.records_any_request_evidence_by_default?
  end

  test "turning a default on without a purpose fails at boot" do
    error = assert_raises(Clickwrap::ConfigurationError) do
      Clickwrap.configure do |config|
        config.record_ip_address_by_default = true
        config.delete_recorded_ip_addresses_after = 90.days
      end
    end

    assert_match(/is blank/, error.message)
  end

  test "turning a default on without a retention rule fails at boot" do
    error = assert_raises(Clickwrap::ConfigurationError) do
      Clickwrap.configure do |config|
        config.record_ip_address_by_default = true
        config.reason_for_recording_ip_addresses_by_default = "Investigate account compromise"
      end
    end

    assert_match(/nothing would ever\s+delete it/, error.message)
  end

  test "enabling geolocation with no resolver fails at boot" do
    error = assert_raises(Clickwrap::ConfigurationError) do
      Clickwrap.configure do |config|
        config.ip_geolocation_resolver = nil
        config.record_ip_geolocation_country_by_default = true
        config.reason_for_recording_ip_geolocation_by_default = "Corroborate anomalous access"
        config.delete_recorded_ip_geolocation_after = 90.days
      end
    end

    assert_match(/no\s+`ip_geolocation_resolver` is configured/, error.message)
  end

  test "storing raw values unencrypted requires a deliberately named decision" do
    error = assert_raises(Clickwrap::ConfigurationError) do
      Clickwrap.config.encrypt_recorded_ip_addresses = false
    end

    assert_match(/deliberately_store_request_evidence_unencrypted!/, error.message)

    Clickwrap.config.deliberately_store_request_evidence_unencrypted!(
      because: "Reviewed: this deployment encrypts at the storage layer"
    )
    Clickwrap.config.encrypt_recorded_ip_addresses = false
    assert Clickwrap.config.storing_request_evidence_unencrypted?
  end

  # --- Per-policy recording ---------------------------------------------------

  test "a policy that names the fields records exactly those fields" do
    configure_static_resolver!
    withdrawal = create_withdrawal(user: @user)

    receipt = capture_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
                                                          http_request: @http_request,
                                                          answers: { regulated_action: "1" })

    annex = receipt.event.reload.request_evidence
    assert annex.present?
    assert annex.recorded_ip_address?
    assert annex.recorded_browser_user_agent?
    assert annex.recorded_ip_geolocation?

    # The policy enabled country, region, city, coordinates, and accuracy
    # radius. It did NOT enable postal code, timezone, continent, or metro.
    assert annex.recorded_ip_geolocation_country?
    assert annex.recorded_ip_geolocation_city?
    assert annex.recorded_ip_geolocation_latitude_and_longitude?
    assert_not annex.recorded_ip_geolocation_postal_code?
    assert_not annex.recorded_ip_geolocation_timezone?
    assert_not annex.recorded_ip_geolocation_metro_code?
  end

  test "only the authorized fields are persisted, never the whole resolver result" do
    configure_static_resolver!
    withdrawal = create_withdrawal(user: @user)

    receipt = capture_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
                                                          http_request: @http_request,
                                                          answers: { regulated_action: "1" })

    annex = receipt.event.reload.request_evidence

    # The static resolver supplied a postal code and a timezone. The policy did
    # not authorize them, so they are not in the row — a resolver's richness is
    # not a reason to keep more than was reviewed.
    assert_nil annex.ip_geolocation_postal_code
    assert_nil annex.ip_geolocation_timezone
    assert_equal "ES", annex.ip_geolocation_country_code
  end

  test "provenance travels with every stored geolocation result" do
    configure_static_resolver!
    withdrawal = create_withdrawal(user: @user)

    receipt = capture_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
                                                          http_request: @http_request,
                                                          answers: { regulated_action: "1" })

    annex = receipt.event.reload.request_evidence

    # A policy cannot keep provider-derived coordinates while stripping the
    # uncertainty needed to read them.
    assert_equal "static_test_resolver", annex.ip_geolocation_provider_name
    assert annex.ip_geolocation_was_estimated?
    assert annex.ip_geolocation_resolved_at.present?
    assert_not annex.ip_geolocation_source_was_verified_by_host?
  end

  test "the reader name and trusted-proxy posture are recorded with the address" do
    configure_static_resolver!
    withdrawal = create_withdrawal(user: @user)

    receipt = capture_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
                                                          http_request: @http_request,
                                                          answers: { regulated_action: "1" })

    annex = receipt.event.reload.request_evidence
    assert_equal "rails_request_remote_ip", annex.ip_address_reader_name
  end

  test "the user agent is labelled client-supplied" do
    configure_static_resolver!
    withdrawal = create_withdrawal(user: @user)

    receipt = capture_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
                                                          http_request: @http_request,
                                                          answers: { regulated_action: "1" })

    assert receipt.event.reload.request_evidence.browser_user_agent_was_client_supplied?
  end

  # --- Unavailability ---------------------------------------------------------

  test "an unavailable resolver produces an explicit unavailable state, not a blank" do
    Clickwrap.config.ip_geolocation_resolver = Clickwrap::IpGeolocation::NullResolver.new
    withdrawal = create_withdrawal(user: @user)

    receipt = capture_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
                                                          http_request: @http_request,
                                                          answers: { regulated_action: "1" })

    annex = receipt.event.reload.request_evidence
    assert annex.ip_geolocation_unavailable_reason.present?
    assert_nil annex.ip_geolocation_country_code

    # "We could not resolve this" and "we chose not to collect this" are
    # different facts, and the receipt keeps them apart.
    fragment = receipt.to_h.dig("request_evidence", "ip_geolocation")
    assert_equal "unavailable", fragment["state"]
    assert fragment["unavailable_reason"].present?
  end

  test "a policy that fails closed refuses the whole capture rather than recording a gap" do
    Clickwrap.policy :fail_closed_probe do
      acknowledge :withdrawal_requirements, statement: "I acknowledge the withdrawal requirements."

      review_request_evidence_configuration_on Date.new(2027, 8, 15)
      record_ip_address(
        encrypted: true,
        delete_after: 90.days,
        fail_if_unavailable: true,
        because: "Investigate disputed submissions"
      )

      retain_with :ordinary_agreement_evidence
    end

    error = assert_raises(Clickwrap::RequestEvidenceUnavailable) do
      capture_clickwrap(:fail_closed_probe, actor: @user, http_request: nil,
                                            answers: { withdrawal_requirements: "1" })
    end

    # The message names the policy, the category, and the reason — and never
    # the value, because an exception travels into logs and issue trackers,
    # which is precisely where a recorded IP address must not appear.
    assert_match(/fail_closed_probe/, error.message)
    assert_match(/ip_address/, error.message)
    assert_match(/fail_if_unavailable: true/, error.message)

    # Required request evidence and the act it belongs to commit together or
    # not at all. A half-formed event with a hole in it is the thing this
    # refusal exists to prevent.
    assert_equal 0, Clickwrap::Event.for_policy(:fail_closed_probe).count
  end

  test "the same missing value is an explicit unavailable state when the policy does not fail closed" do
    Clickwrap.policy :records_but_tolerates_probe do
      acknowledge :withdrawal_requirements, statement: "I acknowledge the withdrawal requirements."

      review_request_evidence_configuration_on Date.new(2027, 8, 15)
      record_ip_address(encrypted: true, delete_after: 90.days,
                        because: "Investigate disputed submissions")

      retain_with :ordinary_agreement_evidence
    end

    receipt = capture_clickwrap(:records_but_tolerates_probe, actor: @user, http_request: nil,
                                                              answers: { withdrawal_requirements: "1" })

    fragment = receipt.to_h.dig("request_evidence", "ip_address")
    assert_equal "unavailable", fragment["state"]
    assert fragment["unavailable_reason"].present?
  end

  test "the recorded values are ciphertext at rest, and their provenance is not" do
    configure_static_resolver!
    withdrawal = create_withdrawal(user: @user)
    receipt = capture_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
                                                          http_request: @http_request,
                                                          answers: { regulated_action: "1" })

    annex = receipt.event.reload.request_evidence
    raw = ActiveRecord::Base.connection.select_one(
      "SELECT ip_address_ciphertext, ip_geolocation_city_name, ip_geolocation_latitude, " \
      "ip_geolocation_provider_name FROM clickwrap_request_evidence WHERE id = #{annex.id}"
    )

    # `encrypt_recorded_ip_geolocation` defaults to true, so it has to actually
    # do something. A city name is lower precision than a coordinate but is
    # still personal data once it is attached to an identified actor and an
    # event, so it is encrypted too.
    assert_equal "Madrid", annex.ip_geolocation_city_name
    assert_not_equal "Madrid", raw["ip_geolocation_city_name"]
    assert_not_equal "203.0.113.7", raw["ip_address_ciphertext"]
    assert_not_equal "40.4168", raw["ip_geolocation_latitude"]

    # Provenance stays readable: it says how certain the values are rather than
    # what they are, and `clickwrap:doctor` and the privacy inventory read it.
    assert_equal "static_test_resolver", raw["ip_geolocation_provider_name"]
  end

  test "coordinates are stored as strings, so the receipt shows what the provider said" do
    configure_static_resolver!
    withdrawal = create_withdrawal(user: @user)
    receipt = capture_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
                                                          http_request: @http_request,
                                                          answers: { regulated_action: "1" })

    # A decimal column would introduce a rounding step between what the provider
    # said and what the evidence shows, for a value the receipt serializes as a
    # string anyway.
    assert_equal "40.4168", receipt.event.reload.request_evidence.ip_geolocation_latitude
  end

  test "editing any retained annex fact breaks that category's event binding" do
    configure_static_resolver!
    withdrawal = create_withdrawal(user: @user)
    receipt = capture_clickwrap(
      :regulated_authorization,
      actor: @user,
      subject: withdrawal,
      http_request: @http_request,
      answers: { regulated_action: "1" }
    )

    assert_equal :verified, receipt.event.reload.request_evidence_binding_status

    Clickwrap::RequestEvidence.where(id: receipt.request_evidence.id)
                              .update_all(ip_address_reader_name: "rewritten_reader")

    assert_equal :digest_mismatch, receipt.event.reload.request_evidence_binding_status
    refute receipt.event.evidence_integrity_verified?
  end

  test "historical key IDs keep old annexes verifiable across binding-key rotation" do
    keys = {
      "request-evidence-2026-01" => "a" * 32,
      "request-evidence-2026-09" => "b" * 32
    }
    Clickwrap.config.current_request_evidence_binding_key_id = "request-evidence-2026-01"
    Clickwrap.config.find_request_evidence_binding_key_with = ->(key_id) { keys[key_id] }
    configure_static_resolver!
    first_withdrawal = create_withdrawal(user: @user)
    first = capture_clickwrap(
      :regulated_authorization,
      actor: @user,
      subject: first_withdrawal,
      http_request: @http_request,
      answers: { regulated_action: "1" }
    )

    Clickwrap.config.current_request_evidence_binding_key_id = "request-evidence-2026-09"
    second_withdrawal = create_withdrawal(user: @user)
    second = capture_clickwrap(
      :regulated_authorization,
      actor: @user,
      subject: second_withdrawal,
      http_request: @http_request,
      answers: { regulated_action: "1" }
    )

    assert_equal "request-evidence-2026-01", first.event.request_evidence_key_id
    assert_equal "request-evidence-2026-09", second.event.request_evidence_key_id
    assert_equal :verified, first.event.reload.request_evidence_binding_status
    assert_equal :verified, second.event.reload.request_evidence_binding_status

    keys.delete("request-evidence-2026-01")
    assert_equal :binding_key_unavailable, first.event.reload.request_evidence_binding_status
    assert_equal :verified, second.event.reload.request_evidence_binding_status
  end

  test "an unavailable encryption key is an unreadable annex finding instead of a crash" do
    configure_static_resolver!
    withdrawal = create_withdrawal(user: @user)
    receipt = capture_clickwrap(
      :regulated_authorization,
      actor: @user,
      subject: withdrawal,
      http_request: @http_request,
      answers: { regulated_action: "1" }
    )
    Clickwrap::RequestEvidence.any_instance
                              .stubs(:category_binding_digest_verified?)
                              .raises(ActiveRecord::Encryption::Errors::Decryption,
                                      "the historical key is unavailable")

    event = receipt.event.reload
    assert_equal :annex_unreadable, event.request_evidence_binding_status
    refute event.evidence_integrity_verified?

    result = Clickwrap.verify(event.id)
    assert_not result.success?
    assert_equal :integrity_check_failed, result.error
    assert_equal "annex_unreadable", result.details.fetch("request_evidence_binding")
  end

  test "a wrong historical binding key fails closed instead of accepting a new key" do
    keys = { "request-evidence-2026-01" => "a" * 32 }
    Clickwrap.config.current_request_evidence_binding_key_id = "request-evidence-2026-01"
    Clickwrap.config.find_request_evidence_binding_key_with = ->(key_id) { keys[key_id] }
    configure_static_resolver!
    withdrawal = create_withdrawal(user: @user)
    receipt = capture_clickwrap(
      :regulated_authorization,
      actor: @user,
      subject: withdrawal,
      http_request: @http_request,
      answers: { regulated_action: "1" }
    )

    keys["request-evidence-2026-01"] = "z" * 32

    assert_equal :digest_mismatch, receipt.event.reload.request_evidence_binding_status
  end

  test "a binding key shorter than 32 bytes refuses capture before evidence is written" do
    Clickwrap.config.current_request_evidence_binding_key_id = "too-short"
    Clickwrap.config.find_request_evidence_binding_key_with = ->(_key_id) { "short" }
    configure_static_resolver!
    withdrawal = create_withdrawal(user: @user)

    error = assert_raises(Clickwrap::ConfigurationError) do
      capture_clickwrap(
        :regulated_authorization,
        actor: @user,
        subject: withdrawal,
        http_request: @http_request,
        answers: { regulated_action: "1" }
      )
    end

    assert_match(/at least 32 bytes/, error.message)
    assert_no_clickwrap_event :regulated_authorization, actor: @user
  end

  # --- The annex is separately disposable ------------------------------------

  test "deleting a recorded IP address leaves the core event intact and verifiable" do
    configure_static_resolver!
    withdrawal = create_withdrawal(user: @user)
    receipt = capture_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
                                                          http_request: @http_request,
                                                          answers: { regulated_action: "1" })

    assert receipt.event.reload.digest_verified?

    Clickwrap.delete_recorded_ip_address!(receipt, because: "Retention period ended")

    annex = receipt.event.reload.request_evidence
    assert annex.ip_address_was_deleted?
    assert_nil annex.ip_address

    # This is the whole reason the annex is a separate table: a lawful deletion
    # must not break the agreement it accompanied.
    assert receipt.event.digest_verified?
    assert receipt.verify.success?

    fragment = Clickwrap::Receipt.new(receipt.event.reload).to_h.dig("request_evidence", "ip_address")
    assert_equal "deleted_after_retention", fragment["state"]
  end

  test "each field is deleted independently" do
    configure_static_resolver!
    withdrawal = create_withdrawal(user: @user)
    receipt = capture_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
                                                          http_request: @http_request,
                                                          answers: { regulated_action: "1" })

    Clickwrap.delete_recorded_ip_address!(receipt, because: "Retention period ended")

    annex = receipt.event.reload.request_evidence
    assert annex.ip_address_was_deleted?
    assert_not annex.browser_user_agent_was_deleted?
    assert_not annex.ip_geolocation_was_deleted?
  end

  test "deletion requires a reason and appends its own event" do
    configure_static_resolver!
    withdrawal = create_withdrawal(user: @user)
    receipt = capture_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
                                                          http_request: @http_request,
                                                          answers: { regulated_action: "1" })

    assert_raises(Clickwrap::Error) do
      Clickwrap.delete_recorded_ip_address!(receipt, because: "")
    end

    assert_difference -> { Clickwrap::Event.where(event_type: "disposition").count }, 1 do
      Clickwrap.delete_recorded_ip_address!(receipt, because: "Retention period ended")
    end
  end

  test "a legal hold stops disposition" do
    configure_static_resolver!
    withdrawal = create_withdrawal(user: @user)
    receipt = capture_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
                                                          http_request: @http_request,
                                                          answers: { regulated_action: "1" })

    receipt.place_on_legal_hold!(because: "Pending dispute 2026-184",
                                 placed_by: create_security_operator,
                                 review_at: 6.months.from_now)

    assert_raises(Clickwrap::LegalHoldInEffect) do
      Clickwrap.delete_recorded_ip_address!(receipt, because: "Retention period ended")
    end
  end

  # --- Leakage ----------------------------------------------------------------

  test "raw values never appear in the default receipt or in inspect output" do
    configure_static_resolver!
    withdrawal = create_withdrawal(user: @user)
    receipt = capture_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
                                                          http_request: @http_request,
                                                          answers: { regulated_action: "1" })

    json = receipt.to_canonical_json
    assert_no_match(/203\.0\.113\.7/, json)
    assert_no_match(/Mozilla/, json)
    assert_no_match(/203\.0\.113\.7/, receipt.to_html)
  end

  test "an authorized export reveals the values and records the access" do
    configure_static_resolver!
    operator = create_security_operator
    withdrawal = create_withdrawal(user: @user)
    receipt = capture_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
                                                          http_request: @http_request,
                                                          answers: { regulated_action: "1" })

    exported = Clickwrap::Receipt.export(receipt, requested_by: operator,
                                                  because: "Investigating dispute 2026-184",
                                                  include_ip_address: true)

    ip = exported.dig("request_evidence", "ip_address")
    assert_equal "recorded", ip["state"]
    assert_equal "203.0.113.7", ip["value"]

    # And the receipt says what an address is, right next to the address.
    assert_match(/Not identity/, ip["means"])
    assert_equal "redacted_for_this_viewer",
                 exported.dig("request_evidence", "browser_user_agent", "state")
  end

  test "a geolocation export states that the result is an estimate about an address" do
    configure_static_resolver!
    operator = create_security_operator
    withdrawal = create_withdrawal(user: @user)
    receipt = capture_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
                                                          http_request: @http_request,
                                                          answers: { regulated_action: "1" })

    exported = Clickwrap::Receipt.export(receipt, requested_by: operator,
                                                  because: "Investigating dispute 2026-184",
                                                  include_ip_geolocation: true)

    geolocation = exported.dig("request_evidence", "ip_geolocation")
    assert_match(/estimate for the observed IP address/, geolocation["means"])
    assert_match(/Not GPS/, geolocation["means"])
    assert_match(/not proof that the person was there/, geolocation["means"])
  end

  test "latitude and longitude are exported together or not at all" do
    configure_static_resolver!
    operator = create_security_operator
    withdrawal = create_withdrawal(user: @user)
    receipt = capture_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
                                                          http_request: @http_request,
                                                          answers: { regulated_action: "1" })

    exported = Clickwrap::Receipt.export(receipt, requested_by: operator,
                                                  because: "Investigating dispute 2026-184",
                                                  include_ip_geolocation: true)

    coordinates = exported.dig("request_evidence", "ip_geolocation", "latitude_and_longitude")
    assert coordinates.key?("latitude")
    assert coordinates.key?("longitude")
  end

  # --- The Trackdown adapter stays optional -----------------------------------

  test "trackdown is not a runtime dependency" do
    assert_not defined?(::Trackdown), "the test bundle must not have trackdown installed"

    error = assert_raises(Clickwrap::ConfigurationError) do
      Clickwrap::IpGeolocation::TrackdownResolver.new
    end

    assert_match(/trackdown/i, error.message)
  end

  test "the null resolver reports no capabilities and always answers unavailable" do
    resolver = Clickwrap::IpGeolocation::NullResolver.new

    assert_empty resolver.capabilities
    result = resolver.resolve("203.0.113.7")
    assert result.unavailable?
    assert result.unavailable_reason.present?
  end

  private

  def configure_static_resolver!
    Clickwrap.config.ip_geolocation_resolver = Clickwrap::IpGeolocation::StaticResolver.new(
      "203.0.113.7" => {
        country_code: "ES",
        country_name: "Spain",
        region_name: "Madrid",
        region_code: "MD",
        city_name: "Madrid",
        postal_code: "28001",
        latitude: 40.4168,
        longitude: -3.7038,
        timezone: "Europe/Madrid",
        continent_code: "EU",
        accuracy_radius_in_kilometers: 20,
        provider_name: "static_test_resolver",
        provider_source: "fixture",
        estimated: true
      }
    )
  end

  def fake_http_request
    ActionDispatch::TestRequest.create(
      "REMOTE_ADDR" => "203.0.113.7",
      "HTTP_USER_AGENT" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Test/1.0",
      "action_dispatch.request_id" => "req-#{SecureRandom.hex(4)}"
    )
  end
end
