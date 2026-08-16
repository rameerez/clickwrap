# frozen_string_literal: true

require "test_helper"

# A contract double for the narrow Devise surface Clickwrap decorates. The
# adapter must never own Devise's create action; it may only wrap the one
# resource.save call that action already makes.
class DeviseRegistrationTest < ActiveSupport::TestCase
  use_real_database_commits!

  class ActualDeviseRegistrationsController < Devise::RegistrationsController
    clickwraps_registration_with :signup
  end

  class DeviseLikeRegistrationsController
    include Clickwrap::ControllerHelpers
    include Clickwrap::Registration

    attr_accessor :resource_to_build, :submitted_clickwrap
    attr_reader :resource, :response_branch, :yielded_resource, :flow_was_cleared

    clickwraps_registration_with :signup

    def create
      build_resource

      if resource.save
        @response_branch = :success
        @yielded_resource = yield(resource) if block_given?
      else
        @response_branch = :failure
      end
    end

    def request
      @request ||= ActionDispatch::TestRequest.create(
        "action_dispatch.request_id" => "devise-contract-request"
      )
    end

    def clickwrap_submission = submitted_clickwrap

    private

    def build_resource(*)
      @resource = resource_to_build
    end

    def clickwrap_registration_flow_id(_policy_key) = "devise-registration-flow"

    def clear_clickwrap_registration_flow_id(_policy_key)
      @flow_was_cleared = true
    end
  end

  class DualWriteRegistrationsController < DeviseLikeRegistrationsController
    clickwraps_registration_with :signup,
                                 after_account_is_saved_inside_transaction: :record_legacy_acceptance!

    def record_legacy_acceptance!(account:, pending_receipt:)
      account.update!(
        accepted_terms_at: Clickwrap.now,
        terms_version: pending_receipt.event_id
      )
    end
  end

  class FailingDualWriteRegistrationsController < DeviseLikeRegistrationsController
    clickwraps_registration_with :signup,
                                 after_account_is_saved_inside_transaction: :fail_legacy_acceptance!

    def fail_legacy_acceptance!(account:, pending_receipt:)
      account.update!(
        accepted_terms_at: Clickwrap.now,
        terms_version: pending_receipt.event_id
      )
      raise "the required legacy write failed"
    end
  end

  test "the adapter leaves create, its success branch, and its yielded block under Devise's control" do
    controller = controller_for(User.new(email: "devise@example.com", name: "Devise Person"))

    result = controller.create { |resource| "yielded-#{resource.email}" }

    assert_equal "yielded-devise@example.com", result
    assert_equal :success, controller.response_branch
    assert_equal "yielded-devise@example.com", controller.yielded_resource
    assert controller.resource.persisted?
    assert controller.flow_was_cleared
    assert_clickwrap_current :signup, actor: controller.resource
    assert_equal "account_registration", Clickwrap::Event.last.attribution_method
  end

  test "the one-save decoration removes itself after Devise has made its registration decision" do
    controller = controller_for(User.new(email: "one-save@example.com", name: "One Save"))

    controller.create

    assert_no_difference -> { Clickwrap::Event.count } do
      assert controller.resource.save
    end
    refute controller.resource.instance_variable_defined?(:@clickwrap_save_installation)
    refute_includes controller.resource.singleton_class.instance_methods(false),
                    :clickwrap_save_without_evidence
  end

  test "the optional adapter loads against real Devise without replacing Devise create" do
    assert_includes ActualDeviseRegistrationsController.ancestors,
                    Clickwrap::Registration::DeviseAdapter
    assert_equal Devise::RegistrationsController,
                 ActualDeviseRegistrationsController.instance_method(:create).owner
    assert_equal Clickwrap::Registration::DeviseAdapter,
                 ActualDeviseRegistrationsController.instance_method(:build_resource).owner
  end

  test "a validation-style save failure follows Devise's failure branch and creates no account evidence" do
    resource = User.new(email: "invalid@example.com", name: "Invalid")
    resource.define_singleton_method(:save) do |*|
      errors.add(:email, "is not accepted")
      false
    end
    controller = controller_for(resource)

    controller.create

    assert_equal :failure, controller.response_branch
    refute controller.resource.persisted?
    assert_includes controller.resource.errors[:email], "is not accepted"
    assert_no_clickwrap_event :signup

    # The host's own singleton implementation is restored, not replaced with
    # Active Record's inherited save after Clickwrap's one attempt.
    assert_equal false, controller.resource.save
    assert_includes controller.resource.errors[:email], "is not accepted"
  end

  test "a declined required statement refuses the signup with localized inline and base errors" do
    resource = User.new(email: "declined-terms@example.com", name: "Declined")
    presentation = present_clickwrap(
      :signup,
      actor: nil,
      prospective_actor: resource,
      registration_flow_id: "devise-registration-flow"
    )
    controller = DeviseLikeRegistrationsController.new.tap do |c|
      c.resource_to_build = resource
      c.submitted_clickwrap = submission_for(presentation, { terms: "0", privacy_notice: "1" })
    end

    controller.create

    assert_equal :failure, controller.response_branch
    refute resource.persisted?
    assert_no_clickwrap_event :signup
    # The person sees the reference screens' sentence, beside the control it
    # belongs to AND on the summary — never a developer-facing message.
    expected = I18n.t("clickwrap.errors.required_statement")
    assert_equal expected, controller.send(:clickwrap_errors)["terms"]
    assert_includes resource.errors[:base], expected
  end

  test "a submission with no clickwrap envelope refuses the signup instead of raising" do
    resource = User.new(email: "no-envelope@example.com", name: "Cached Form")
    controller = DeviseLikeRegistrationsController.new.tap do |c|
      c.resource_to_build = resource
      c.submitted_clickwrap = nil
    end

    controller.create

    assert_equal :failure, controller.response_branch
    refute User.exists?(email: "no-envelope@example.com")
    assert_no_clickwrap_event :signup
    assert_includes resource.errors[:base], I18n.t("clickwrap.errors.presentation_no_longer_valid")
  end

  test "an evidence write failure escapes and rolls the account back before Devise can sign it in" do
    controller = controller_for(User.new(email: "atomic-devise@example.com", name: "Atomic"))

    Clickwrap::Testing.fail_next_event_write do
      assert_raises(Clickwrap::EventWriteFailed) { controller.create }
    end

    refute User.exists?(email: "atomic-devise@example.com")
    assert_nil controller.response_branch
    assert_no_clickwrap_event :signup
  end

  test "the registration flow is cleared only after a host-owned outer transaction commits" do
    controller = controller_for(User.new(email: "outer-commit@example.com", name: "Outer Commit"))

    ActiveRecord::Base.transaction(joinable: false) do
      controller.create

      refute controller.flow_was_cleared
      assert User.exists?(email: "outer-commit@example.com")
    end

    assert controller.flow_was_cleared
    assert User.exists?(email: "outer-commit@example.com")
  end

  test "a rolled-back outer transaction leaves the registration flow available for a retry" do
    controller = controller_for(User.new(email: "outer-rollback@example.com", name: "Outer Rollback"))

    ActiveRecord::Base.transaction(joinable: false) do
      controller.create
      raise ActiveRecord::Rollback
    end

    refute controller.flow_was_cleared
    refute User.exists?(email: "outer-rollback@example.com")
    assert_no_clickwrap_event :signup
  end

  test "a required legacy dual-write runs inside the account and evidence transaction" do
    resource = User.new(email: "dual-write@example.com", name: "Dual Write")
    controller = controller_for(resource, controller_class: DualWriteRegistrationsController)

    controller.create

    account = User.find_by!(email: resource.email)
    assert account.accepted_terms_at.present?
    assert_equal Clickwrap::Event.captures.for_policy("signup").last.id, account.terms_version
    assert_clickwrap_current :signup, actor: account
  end

  test "a failed required dual-write rolls the account and evidence back together" do
    resource = User.new(email: "dual-write-failure@example.com", name: "Dual Write Failure")
    controller = controller_for(resource, controller_class: FailingDualWriteRegistrationsController)

    assert_raises(RuntimeError) { controller.create }

    refute User.exists?(email: resource.email)
    assert_no_clickwrap_event :signup
  end

  private

  def controller_for(resource, controller_class: DeviseLikeRegistrationsController)
    presentation = present_clickwrap(
      :signup,
      actor: nil,
      prospective_actor: resource,
      registration_flow_id: "devise-registration-flow"
    )
    controller_class.new.tap do |controller|
      controller.resource_to_build = resource
      controller.submitted_clickwrap = submission_for(
        presentation,
        { terms: "1", privacy_notice: "1" }
      )
    end
  end
end
