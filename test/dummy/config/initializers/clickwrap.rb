# frozen_string_literal: true

class DummyIpGeolocationResolver
  def resolve(_ip_address, http_request: nil) = nil
  def capabilities = Clickwrap::Vocabulary::IP_GEOLOCATION_DATA_FIELDS.map(&:to_sym)
end

# Minimal host wiring, close to what the install generator writes. Tests that
# exercise other configurations set them per-test (Clickwrap.reset! plus a
# re-configure in setup/teardown keeps this from leaking).
Clickwrap.configure do |config|
  config.actor_class_name = "User"
  config.current_actor_method_name = :current_user
  config.parent_controller_class_name = "ApplicationController"

  config.find_current_tenant_with = lambda do |controller|
    controller.current_organization if controller.respond_to?(:current_organization)
  end

  config.authorize_receipt_access_with = lambda do |controller, receipt|
    controller.current_user&.clickwrap_actor_reference == receipt.actor_reference
  end

  # Deliberately NOT the default. The dummy needs a way to exercise the
  # unredacted-export path, and this is what a host writes when it has decided
  # who may read raw request evidence and required them to say why.
  config.authorize_unredacted_request_evidence_access_with = lambda do |requested_by, _receipt, because|
    requested_by.respond_to?(:security_operator?) && requested_by.security_operator? && because.present?
  end

  config.authorize_clickwrap_remediation_subject_with = lambda do |actor:, subject:, policy:, controller:|
    subject.nil? || (subject.respond_to?(:user_id) && subject.user_id == actor&.id)
  end

  config.authorize_clickwrap_remediation_represented_party_with =
    lambda do |actor:, represented_party:, policy:, controller:|
      represented_party.nil? || controller.current_organization == represented_party
    end

  config.application_version = -> { "dummy-test" }

  # The dummy's request-evidence policy is compiled at boot, so its reviewed
  # network provenance and deterministic test resolver are real configuration,
  # not test-time patches applied after the revision was frozen.
  config.trusted_proxy_configuration_digest =
    Clickwrap::Digest.digest("dummy-host-reviewed-trusted-proxy-configuration-v1")
  config.ip_geolocation_resolver = DummyIpGeolocationResolver.new

  config.calculate_retention_time_for :regulated_evidence_retention_ends do |event|
    [
      event.recorded_at_by_server + 5.years,
      event.subject.respond_to?(:liquidated_at) ? event.subject.liquidated_at&.+(3.years) : nil
    ].compact.max
  end

  config.calculate_retention_time_for :security_evidence_retention_ends do |event|
    event.recorded_at_by_server + 2.years
  end
end
