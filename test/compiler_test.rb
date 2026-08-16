# frozen_string_literal: true

require "test_helper"

class CompilerTest < ActiveSupport::TestCase
  test "tenant scope is explicit, frozen into the policy, and validated" do
    personal = Clickwrap.policy :personal_tenant_contract do
      tenant_is :not_applicable
      agree_to :terms
      retain_with :ordinary_agreement_evidence
    end

    tenant_bound = Clickwrap.policy :required_tenant_contract do
      tenant_is :required
      agree_to :terms
      retain_with :ordinary_agreement_evidence
    end

    assert_equal "not_applicable", personal.snapshot.fetch("tenant_scope")
    assert_nil personal.tenant_from_controller(create_organization)
    assert_raises(Clickwrap::DefinitionError) { personal.validate_tenant!(create_organization) }
    assert_raises(Clickwrap::DefinitionError) { tenant_bound.validate_tenant!(nil) }

    error = assert_raises(Clickwrap::DefinitionError) do
      Clickwrap.policy :ambiguous_tenant_contract do
        tenant_is :sometimes
        agree_to :terms
        retain_with :ordinary_agreement_evidence
      end
    end
    assert_match(/not_applicable.*optional.*required/, error.message)
  end

  test "unknown document, statement, request-evidence, policy, retention, and initializer names are refused" do
    assert_raises(Clickwrap::DefinitionError) do
      Clickwrap.document(:mistyped_document, version: "1", content: "text", media_typo: "text/plain")
    end

    statement_error = assert_raises(Clickwrap::DefinitionError) do
      Clickwrap.policy :mistyped_statement_option do
        agree_to :terms, require_current_versions: true
        retain_with :ordinary_agreement_evidence
      end
    end
    assert_match(/require_current_versions/, statement_error.message)
    assert_match(/never ignores policy options/, statement_error.message)

    assert_raises(Clickwrap::DefinitionError) do
      Clickwrap.policy :mistyped_request_evidence_option do
        agree_to :terms
        record_ip_address(becuz: "typo")
        retain_with :ordinary_agreement_evidence
      end
    end

    assert_raises(Clickwrap::DefinitionError) do
      Clickwrap.policy :mistyped_policy_method do
        agrees_to :terms
        retain_with :ordinary_agreement_evidence
      end
    end

    assert_raises(Clickwrap::DefinitionError) do
      Clickwrap.retention :mistyped_retention_method do
        retain_core_events_for 1.year
      end
    end

    initializer_error = assert_raises(Clickwrap::ConfigurationError) do
      Clickwrap.config.public_send(:record_ip_adress_by_default=, true)
    end
    assert_match(/no initializer setting/, initializer_error.message)
  end

  test "duplicate registry keys and duplicate retention parts are refused" do
    Clickwrap.policy :one_stable_policy_key do
      agree_to :terms
      retain_with :ordinary_agreement_evidence
    end

    assert_raises(Clickwrap::DefinitionError) do
      Clickwrap.policy :one_stable_policy_key do
        acknowledge :privacy_notice
        retain_with :ordinary_agreement_evidence
      end
    end

    Clickwrap.document :unique_document_key, version: "1", content: "first"
    assert_raises(Clickwrap::DefinitionError) do
      Clickwrap.document :unique_document_key, version: "1", content: "second"
    end

    assert_raises(Clickwrap::DefinitionError) do
      Clickwrap.retention :contradictory_retention do
        retain_core_event_for 1.year
        retain_core_event_until :closed_at
      end
    end
  end

  test "the post-load pass resolves documents and retention classes" do
    Clickwrap.policy :missing_document_reference do
      agree_to :document_that_does_not_exist
      retain_with :ordinary_agreement_evidence
    end

    error = assert_raises(Clickwrap::DefinitionError) do
      Clickwrap::Services::ValidatePolicyReferences.call
    end
    assert_match(/document_that_does_not_exist/, error.message)
  end

  test "the post-load pass resolves every named host retention calculation" do
    Clickwrap.retention :unresolved_calculation_retention do
      retain_core_event_for 1.year
      retain_recorded_ip_address_until :misspelled_security_deadline
    end

    Clickwrap.policy :unresolved_calculation_policy do
      agree_to :terms
      record_ip_address because: "Investigate disputed acceptance"
      retain_with :unresolved_calculation_retention
    end

    error = assert_raises(Clickwrap::DefinitionError) do
      Clickwrap::Services::ValidatePolicyReferences.call
    end
    assert_match(/misspelled_security_deadline/, error.message)
    assert_match(/calculate_retention_time_for/, error.message)
  end

  test "application request-evidence defaults are frozen into the policy revision at compile time" do
    original = Clickwrap.policy!(:signup)
    original_revision = original.revision
    refute original.request_evidence.records_ip_address?

    Clickwrap.configure do |config|
      config.record_ip_address_by_default = true
      config.reason_for_recording_ip_addresses_by_default = "Investigate disputed acceptance"
      config.delete_recorded_ip_addresses_after = 30.days
    end

    # A live policy cannot change underneath an already rendered form merely
    # because somebody mutated the configuration object.
    refute original.request_evidence.records_ip_address?
    assert_equal original_revision, original.revision

    Clickwrap::Services::LoadPolicies.new(
      root: Rails.root.to_s, paths: ["config/clickwrap.rb"]
    ).call
    recompiled = Clickwrap.policy!(:signup)

    assert recompiled.request_evidence.records_ip_address?
    assert_equal 30.days.to_i,
                 recompiled.request_evidence.ip_address.to_snapshot.fetch("delete_after_seconds")
    assert_not_equal original_revision, recompiled.revision
  end

  test "a policy can explicitly turn an application request-evidence default off" do
    Clickwrap.configure do |config|
      config.record_ip_address_by_default = true
      config.reason_for_recording_ip_addresses_by_default = "Investigate disputed acceptance"
      config.delete_recorded_ip_addresses_after = 30.days
    end

    policy = Clickwrap.policy :privacy_narrower_than_application do
      agree_to :terms
      do_not_record_ip_address
      retain_with :ordinary_agreement_evidence
    end

    refute policy.request_evidence.records_ip_address?
    assert_equal false, policy.snapshot.dig("request_evidence", "ip_address", "record")
  end

  test "coordinates without an explicitly authorized accuracy radius fail at compile time" do
    error = assert_raises(Clickwrap::DefinitionError) do
      Clickwrap.policy :coordinates_without_uncertainty do
        authorize :regulated_action,
                  document: :withdrawal_requirements,
                  one_time: true,
                  valid_for: 10.minutes
        record_ip_geolocation(
          latitude_and_longitude: true,
          accuracy_radius_in_kilometers: false,
          delete_after: 30.days,
          because: "Investigate anomalous regulated actions"
        )
        retain_with :regulated_evidence
      end
    end

    assert_match(/will not enable another field silently/, error.message)
  end

  test "a retention-class annex rule is an executable fallback" do
    policy = Clickwrap.policy :retention_class_annex_fallback do
      agree_to :terms
      record_ip_address because: "Investigate disputed acceptance"
      retain_with :ordinary_agreement_evidence
    end

    Clickwrap::Services::ValidatePolicyReferences.call
    result = Clickwrap::RequestEvidenceExtractor.new(
      policy:,
      http_request: ActionDispatch::TestRequest.create("REMOTE_ADDR" => "203.0.113.17"),
      capture_channel: :web_browser
    ).extract

    deadline = result.attributes.fetch(:ip_address_delete_after)
    assert_in_delta 90.days.to_i, deadline - Time.current, 5
  end

  test "a local consent withdrawal path must resolve to a real GET route" do
    Clickwrap.policy :dead_withdrawal_route do
      consent_to :product_updates,
                 document: :marketing_notice,
                 optional: true,
                 withdrawal_path: "/definitely-not-a-real-route"
      retain_with :marketing_consent_evidence
    end

    error = assert_raises(Clickwrap::DefinitionError) do
      Clickwrap::Services::ValidatePolicyReferences.validate_remediation_paths!
    end
    assert_match(/no GET route/, error.message)
  end

  test "one protected action cannot declare two competing outcome recorders" do
    error = assert_raises(Clickwrap::DefinitionError) do
      Clickwrap.policy :two_outcomes_for_one_action do
        authorize :first_action,
                  document: :withdrawal_requirements,
                  statement: "I authorize the first action.",
                  valid_for: 10.minutes,
                  protected_outcome_version: "first-v1",
                  record_protected_outcome_with: ->(result) { result }
        authorize :second_action,
                  document: :withdrawal_requirements,
                  statement: "I authorize the second action.",
                  valid_for: 10.minutes,
                  protected_outcome_version: "second-v1",
                  record_protected_outcome_with: ->(result) { result }
        retain_with :regulated_evidence
      end
    end

    assert_match(/one protected action has one result snapshot/i, error.message)
  end
end
