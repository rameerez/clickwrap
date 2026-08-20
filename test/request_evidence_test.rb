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
    receipt = submit_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })

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

  # --- The one switch ---------------------------------------------------------

  test "the one switch records the coarse trio and nothing finer" do
    Clickwrap.configure { |config| config.record_request_evidence_by_default = true }

    config = Clickwrap.config
    assert config.record_request_evidence_by_default
    assert config.record_ip_address_by_default
    assert config.record_browser_user_agent_by_default
    assert_equal %w[country region city], config.enabled_default_ip_geolocation_fields

    (Clickwrap::Vocabulary::IP_GEOLOCATION_DATA_FIELDS -
      Clickwrap::Vocabulary::COARSE_IP_GEOLOCATION_DATA_FIELDS).each do |field|
      assert_not config.public_send(:"record_ip_geolocation_#{field}_by_default"),
                 "the switch must not enable #{field}"
    end
  end

  test "the switch composes with the per-field flags in reading order" do
    Clickwrap.configure do |config|
      config.record_request_evidence_by_default = true
      config.record_browser_user_agent_by_default = false
    end

    assert Clickwrap.config.record_ip_address_by_default
    assert_not Clickwrap.config.record_browser_user_agent_by_default
    assert_not Clickwrap.config.record_request_evidence_by_default,
               "the reader describes the trio, and one of them is off"
  end

  test "turning the switch off leaves the separately named finer fields alone" do
    Clickwrap.configure do |config|
      config.record_ip_geolocation_timezone_by_default = true
      config.record_request_evidence_by_default = true
      config.record_request_evidence_by_default = false
    end

    assert_not Clickwrap.config.record_ip_address_by_default
    assert_equal %w[timezone], Clickwrap.config.enabled_default_ip_geolocation_fields
  end

  test "the switch is a boolean, not a mode name that could hide a third state" do
    error = assert_raises(Clickwrap::ConfigurationError) do
      Clickwrap.config.record_request_evidence_by_default = :everything
    end

    assert_match(/record_request_evidence_by_default must be true or false/, error.message)
  end

  test "a policy narrower than the switch still wins" do
    Clickwrap.configure { |config| config.record_request_evidence_by_default = true }

    policy = Clickwrap.policy :narrower_than_the_switch do
      agree_to :terms
      do_not_record_ip_address
      do_not_record_ip_geolocation
    end

    assert_not policy.request_evidence.records_ip_address?
    assert_not policy.request_evidence.records_ip_geolocation?
    assert policy.request_evidence.records_browser_user_agent?
  end

  test "a policy wider than the switch still wins" do
    policy = Clickwrap.policy :wider_than_the_switch do
      agree_to :terms
      record_ip_address because: "Investigate disputed acceptance"
    end

    assert policy.request_evidence.records_ip_address?
    assert_equal "host", policy.request_evidence.purpose_source_for(:ip_address)
    assert_not policy.request_evidence.records_browser_user_agent?
  end

  # --- Zero-keyword declarations ----------------------------------------------

  test "every record_ verb works with no keyword arguments at all" do
    policy = Clickwrap.policy :zero_keyword_request_evidence do
      agree_to :terms
      record_ip_address
      record_browser_user_agent
      record_ip_geolocation
    end

    request_evidence = policy.request_evidence
    assert request_evidence.records_ip_address?
    assert request_evidence.records_browser_user_agent?
    assert request_evidence.records_ip_geolocation?

    # No field named means the same coarse trio the one switch turns on.
    assert_equal %w[country region city], request_evidence.enabled_ip_geolocation_fields

    Clickwrap::RequestEvidencePolicy::FIELD_CATEGORIES.each do |category|
      setting = request_evidence.setting_for(category)
      assert_equal Clickwrap::Vocabulary::DEFAULT_REQUEST_EVIDENCE_PURPOSE, setting.because
      assert_equal "gem_default", request_evidence.purpose_source_for(category)
      assert_nil setting.legal_basis_reference
      assert_nil setting.delete_after
      assert_nil setting.retain_until
    end
  end

  test "a zero-keyword declaration captures and stores exactly the coarse trio" do
    configure_static_resolver!
    Clickwrap.policy(:zero_keyword_capture) do
      agree_to :terms
      record_ip_address
      record_ip_geolocation
    end
    Clickwrap::Services::ValidatePolicyReferences.call

    receipt = submit_clickwrap(:zero_keyword_capture, actor: @user, http_request: @http_request)
    annex = receipt.event.reload.request_evidence

    assert_equal "203.0.113.7", annex.ip_address
    assert annex.recorded_ip_geolocation_country?
    assert annex.recorded_ip_geolocation_city?
    assert_not annex.recorded_ip_geolocation_latitude_and_longitude?
    assert_not annex.recorded_ip_geolocation_postal_code?
  end

  test "naming even one geolocation field means you chose the whole set" do
    policy = Clickwrap.policy :one_named_geolocation_field do
      agree_to :terms
      record_ip_geolocation country: true
    end

    assert_equal %w[country], policy.request_evidence.enabled_ip_geolocation_fields
  end

  test "naming every geolocation field false is refused as meaningless" do
    error = assert_raises(Clickwrap::DefinitionError) do
      Clickwrap.policy :all_geolocation_fields_off do
        agree_to :terms
        record_ip_geolocation country: false, region: false, city: false
      end
    end

    assert_match(/turns every field off/, error.message)
    assert_match(/do_not_record_ip_geolocation/, error.message)
  end

  test "a legal basis reference is never required, at either level" do
    Clickwrap.configure { |config| config.record_request_evidence_by_default = true }
    switched = Clickwrap.policy(:no_legal_basis_by_default) { agree_to :terms }

    assert switched.request_evidence.records_ip_address?
    assert_nil switched.request_evidence.ip_address.legal_basis_reference

    named = Clickwrap.policy :no_legal_basis_named do
      agree_to :terms
      record_ip_address because: "Investigate disputed acceptance"
    end

    assert_nil named.request_evidence.ip_address.legal_basis_reference
    assert_nil named.request_evidence.ip_address.data_protection_impact_assessment_reference
  end

  # --- Gem-supplied defaults --------------------------------------------------

  test "turning a default on without a purpose records the purpose Clickwrap states" do
    Clickwrap.configure do |config|
      config.record_ip_address_by_default = true
      config.delete_recorded_ip_addresses_after = 90.days
    end

    policy = Clickwrap.policy(:purpose_supplied_by_the_gem) { agree_to :terms }
    setting = policy.request_evidence.ip_address

    assert_equal Clickwrap::Vocabulary::DEFAULT_REQUEST_EVIDENCE_PURPOSE, setting.because
    assert_equal "gem_default", policy.request_evidence.purpose_source_for(:ip_address)
    assert_equal Clickwrap::Vocabulary::DEFAULT_REQUEST_EVIDENCE_PURPOSE,
                 policy.snapshot.dig("request_evidence", "ip_address", "because"),
                 "the compiled revision always carries a purpose"
  end

  test "a purpose the host wrote stays the host's own words" do
    Clickwrap.configure do |config|
      config.record_ip_address_by_default = true
      config.reason_for_recording_ip_addresses_by_default = "Investigate account compromise"
    end

    policy = Clickwrap.policy(:purpose_supplied_by_the_host) { agree_to :terms }

    assert_equal "Investigate account compromise", policy.request_evidence.ip_address.because
    assert_equal "host", policy.request_evidence.purpose_source_for(:ip_address)
  end

  test "scaffolding text is still not a purpose, wherever the host wrote it" do
    application = assert_raises(Clickwrap::ConfigurationError) do
      Clickwrap.configure do |config|
        config.record_ip_address_by_default = true
        config.reason_for_recording_ip_addresses_by_default = "TODO: ask legal"
      end
    end
    assert_match(/scaffolding text/, application.message)

    policy = assert_raises(Clickwrap::DefinitionError) do
      Clickwrap.policy :scaffolded_purpose do
        agree_to :terms
        record_ip_address because: "FIXME"
      end
    end
    assert_match(/scaffolding text/, policy.message)
  end

  test "turning a default on without a retention rule keeps pace with the evidence" do
    Clickwrap.configure do |config|
      config.record_ip_address_by_default = true
      config.reason_for_recording_ip_addresses_by_default = "Investigate account compromise"
    end

    assert Clickwrap.config.validate!
    assert_nil Clickwrap.config.delete_recorded_ip_addresses_after

    Clickwrap.policy(:no_clock_anywhere) { agree_to :terms }
    Clickwrap::Services::ValidatePolicyReferences.call

    receipt = submit_clickwrap(:no_clock_anywhere, actor: @user, http_request: @http_request)
    annex = receipt.event.reload.request_evidence

    assert_equal "203.0.113.7", annex.ip_address
    assert_nil annex.ip_address_delete_after, "no schedule IS the disposal answer"
    assert_nil annex.ip_address_retain_until_rule
  end

  test "an IP address recorded with no reviewed proxy configuration says so honestly" do
    Clickwrap.configure do |config|
      config.trusted_proxy_configuration_digest = nil
      config.record_ip_address_by_default = true
    end

    Clickwrap.policy(:unreviewed_proxy_topology) { agree_to :terms }
    receipt = submit_clickwrap(:unreviewed_proxy_topology, actor: @user, http_request: @http_request)
    annex = receipt.event.reload.request_evidence

    assert_equal "203.0.113.7", annex.ip_address
    assert_nil annex.trusted_proxy_configuration_digest,
               "the absence is the provenance: nobody recorded a reviewed proxy configuration"
    assert_equal "rails_request_remote_ip", annex.ip_address_reader_name,
                 "which reader was asked is still recorded, digest or no digest"
  end

  test "enabling geolocation with no resolver and no trackdown fails at boot" do
    error = assert_raises(Clickwrap::ConfigurationError) do
      Clickwrap.configure do |config|
        config.ip_geolocation_resolver = nil
        config.record_ip_geolocation_country_by_default = true
        config.reason_for_recording_ip_geolocation_by_default = "Corroborate anomalous access"
        config.delete_recorded_ip_geolocation_after = 90.days
      end
    end

    assert_match(/no\s+`ip_geolocation_resolver` is configured/, error.message)
    assert_match(/bundle add trackdown/, error.message)
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

    receipt = submit_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
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

    receipt = submit_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
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

    receipt = submit_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
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

    receipt = submit_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
                                                         http_request: @http_request,
                                                         answers: { regulated_action: "1" })

    annex = receipt.event.reload.request_evidence
    assert_equal "rails_request_remote_ip", annex.ip_address_reader_name
  end

  test "the user agent is labelled client-supplied" do
    configure_static_resolver!
    withdrawal = create_withdrawal(user: @user)

    receipt = submit_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
                                                         http_request: @http_request,
                                                         answers: { regulated_action: "1" })

    assert receipt.event.reload.request_evidence.browser_user_agent_was_client_supplied?
  end

  # --- Unavailability ---------------------------------------------------------

  test "an unavailable resolver produces an explicit unavailable state, not a blank" do
    Clickwrap.config.ip_geolocation_resolver = Clickwrap::IpGeolocation::NullResolver.new
    withdrawal = create_withdrawal(user: @user)

    receipt = submit_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
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
      submit_clickwrap(:fail_closed_probe, actor: @user, http_request: nil,
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

    receipt = submit_clickwrap(:records_but_tolerates_probe, actor: @user, http_request: nil,
                                                             answers: { withdrawal_requirements: "1" })

    fragment = receipt.to_h.dig("request_evidence", "ip_address")
    assert_equal "unavailable", fragment["state"]
    assert fragment["unavailable_reason"].present?
  end

  test "the recorded values are ciphertext at rest, and their provenance is not" do
    configure_static_resolver!
    withdrawal = create_withdrawal(user: @user)
    receipt = submit_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
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
    receipt = submit_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
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
    receipt = submit_clickwrap(
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
    first = submit_clickwrap(
      :regulated_authorization,
      actor: @user,
      subject: first_withdrawal,
      http_request: @http_request,
      answers: { regulated_action: "1" }
    )

    Clickwrap.config.current_request_evidence_binding_key_id = "request-evidence-2026-09"
    second_withdrawal = create_withdrawal(user: @user)
    second = submit_clickwrap(
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
    receipt = submit_clickwrap(
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
    receipt = submit_clickwrap(
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
      submit_clickwrap(
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
    receipt = submit_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
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
    receipt = submit_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
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
    receipt = submit_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
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
    receipt = submit_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
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
    receipt = submit_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
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
    receipt = submit_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
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
    receipt = submit_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
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
    receipt = submit_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
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
