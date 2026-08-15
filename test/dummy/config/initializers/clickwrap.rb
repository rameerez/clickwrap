# frozen_string_literal: true

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

  config.authorize_receipt_access_with = ->(controller, receipt) { controller.current_user&.clickwrap_actor_reference == receipt.actor_reference }

  # Deliberately NOT the default. The dummy needs a way to exercise the
  # unredacted-export path, and this is what a host writes when it has decided
  # who may read raw request evidence and required them to say why.
  config.authorize_unredacted_request_evidence_access_with = lambda do |requested_by, _receipt, because|
    requested_by.respond_to?(:security_operator?) && requested_by.security_operator? && because.present?
  end

  config.application_version = -> { "dummy-test" }
end
