# frozen_string_literal: true

require "test_helper"

# The `save` / `save!` pairing for doors and captures. The bang forms raise;
# the plain forms absorb REFUSALS — a stale presentation, an unticked control,
# a failed validation — into the same human sentences the Devise adapter
# paints, then return false, so every door in an application refuses in
# identical language by construction. What they must NEVER absorb is an
# infrastructure failure: a broken database is not a refusal to dress up as
# validation.
class RefusalAbsorbingHelpersTest < ActiveSupport::TestCase
  # The smallest hand-rolled door: exactly what a Rails-authentication-
  # generator app or an OAuth finish screen builds around these helpers.
  class HandRolledDoorController
    include Clickwrap::ControllerHelpers

    attr_accessor :submitted_clickwrap

    def request
      @request ||= ActionDispatch::TestRequest.create(
        "action_dispatch.request_id" => "hand-rolled-door-request"
      )
    end

    def clickwrap_submission = submitted_clickwrap

    private

    def clickwrap_registration_flow_id(_policy_key) = "hand-rolled-registration-flow"
    def clear_clickwrap_registration_flow_id(_policy_key); end
  end

  # --- register_with_clickwrap (the non-bang door) ---------------------------

  test "a completed submission registers the account and returns the result" do
    user = User.new(email: "hand-rolled@example.com", name: "Hand Rolled")
    controller = door_for(user)

    result = controller.register_with_clickwrap(:signup, user: user) { user.save! }

    assert result
    assert user.persisted?
    assert_nil controller.clickwrap_refusal
    assert_clickwrap_current :signup, actor: user
  end

  test "there is one spelling for the record the door creates" do
    user = User.new(email: "one-spelling@example.com", name: "One Spelling")
    controller = door_for(user)

    # `prospective_actor:` used to be a second, undocumented name for the same
    # argument, with silent precedence over `user:`. Removing it has to be
    # LOUD: the keyword would otherwise ride the `**` forward straight into
    # Registration.perform and go on working invisibly.
    error = assert_raises(ArgumentError) do
      controller.register_with_clickwrap(:signup, user: user, prospective_actor: user) { user.save! }
    end

    assert_match(/does not take `prospective_actor:`/, error.message)
    assert_not user.persisted?
  end

  test "an unticked control is absorbed in exactly the Devise adapter's language" do
    user = User.new(email: "unticked@example.com", name: "Unticked")
    controller = door_for(user, answers: { terms: "0", privacy_notice: "1" })

    result = controller.register_with_clickwrap(:signup, user: user) { user.save! }

    assert_equal false, result
    refute user.persisted?
    assert_no_clickwrap_event :signup
    assert_includes user.errors[:base], I18n.t("clickwrap.errors.required_statement")
    assert_equal I18n.t("clickwrap.errors.required_statement"),
                 controller.clickwrap_errors["terms"],
                 "the message lands beside the control it belongs to"
    assert_instance_of Clickwrap::AnswerInvalid, controller.clickwrap_refusal
  end

  test "a missing clickwrap envelope is absorbed as a person on a stale render" do
    user = User.new(email: "stripped@example.com", name: "Stripped")
    controller = HandRolledDoorController.new
    controller.submitted_clickwrap = nil

    result = controller.register_with_clickwrap(:signup, user: user) { user.save! }

    assert_equal false, result
    refute user.persisted?
    assert_includes user.errors[:base], I18n.t("clickwrap.errors.presentation_no_longer_valid")
  end

  test "a validation failure inside the block comes back on the record" do
    user = User.new(email: "invalid@example.com", name: "Invalid")
    user.define_singleton_method(:save!) do |*|
      errors.add(:email, "is not accepted")
      raise ActiveRecord::RecordInvalid, self
    end
    controller = door_for(user)

    result = controller.register_with_clickwrap(:signup, user: user) { user.save! }

    assert_equal false, result
    assert_includes user.errors[:email], "is not accepted"
    assert_no_clickwrap_event :signup
  end

  test "register_with_clickwrap! still raises, for flows that handle refusals themselves" do
    user = User.new(email: "bang@example.com", name: "Bang")
    controller = door_for(user, answers: { terms: "0", privacy_notice: "1" })

    assert_raises(Clickwrap::AnswerInvalid) do
      controller.register_with_clickwrap!(:signup, user: user) { user.save! }
    end
  end

  test "an evidence write failure escapes from BOTH forms and rolls the account back" do
    user = User.new(email: "atomic-nonbang@example.com", name: "Atomic")
    controller = door_for(user)

    Clickwrap::Testing.fail_next_event_write do
      assert_raises(Clickwrap::EventWriteFailed) do
        controller.register_with_clickwrap(:signup, user: user) { user.save! }
      end
    end

    refute User.exists?(email: "atomic-nonbang@example.com")
    assert_no_clickwrap_event :signup
  end

  # --- capture_clickwrap_and / capture_clickwrap -----------------------------

  test "a refused capture returns false with the human sentence ready to show" do
    user = create_user
    controller = door_for(nil)
    controller.submitted_clickwrap = nil
    ran = false

    result = controller.capture_clickwrap_and(:signup, actor: user) { ran = true }

    assert_equal false, result
    refute ran, "the protected action must not run without accepted evidence"
    assert_kind_of Clickwrap::CaptureRefused, controller.clickwrap_refusal
    assert controller.clickwrap_refusal.user_facing_message.present?,
           "the refusal carries a complete sentence fit to put in front of a person"
  end

  test "a completed capture returns the receipt and leaves no refusal behind" do
    user = create_user
    presentation = present_clickwrap(:signup, actor: user)
    controller = door_for(nil)
    controller.submitted_clickwrap = submission_for(presentation, terms: "1", privacy_notice: "1")
    ran = false

    receipt = controller.capture_clickwrap_and(:signup, actor: user) { ran = true }

    assert receipt
    assert ran
    assert_nil controller.clickwrap_refusal
  end

  test "an exact replay stays idempotent, and a conflicting replay still raises" do
    user = create_user
    presentation = present_clickwrap(:research_contact, actor: user)
    accepted = submission_for(presentation, { research_contact: "yes" })

    first = door_for(nil)
    first.submitted_clickwrap = accepted
    original = first.capture_clickwrap(:research_contact, actor: user)
    assert original

    # The same submission again is a retried request, not a refusal: the same
    # receipt comes back and nothing is absorbed.
    retried = door_for(nil)
    retried.submitted_clickwrap = accepted
    replayed = retried.capture_clickwrap(:research_contact, actor: user)
    assert_equal original.event_id, replayed.event_id
    assert_nil retried.clickwrap_refusal

    # A replay with DIFFERENT answers is neither a refusal nor a retry —
    # "already answered, differently" needs a domain response, so it raises
    # straight through the non-bang form.
    conflicting = door_for(nil)
    conflicting.submitted_clickwrap = submission_for(presentation, { research_contact: "no" })
    assert_raises(Clickwrap::ReplayRejected) do
      conflicting.capture_clickwrap(:research_contact, actor: user)
    end
  end

  private

  def door_for(resource, answers: { terms: "1", privacy_notice: "1" })
    controller = HandRolledDoorController.new
    if resource
      presentation = present_clickwrap(
        :signup,
        actor: nil,
        prospective_actor: resource,
        registration_flow_id: "hand-rolled-registration-flow"
      )
      controller.submitted_clickwrap = submission_for(presentation, answers)
    end
    controller
  end
end
