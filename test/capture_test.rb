# frozen_string_literal: true

require "test_helper"

# The guarantee this gem exists to make: required evidence and the protected
# database action commit together, or neither commits.
class CaptureTest < ActiveSupport::TestCase
  setup do
    @user = create_user
  end

  # --- The ordinary path ------------------------------------------------------

  test "capture records one event with one statement per act" do
    receipt = capture_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })

    assert_equal "capture", receipt.event.event_type
    assert_equal "signup", receipt.policy_key
    assert_equal %w[privacy_notice terms], receipt.statements.map(&:statement_key).sort

    terms = receipt.statements.find { |statement| statement.statement_key == "terms" }
    privacy = receipt.statements.find { |statement| statement.statement_key == "privacy_notice" }

    # One event and one receipt, but never one meaning. Agreeing to terms and
    # acknowledging a notice stay separate acts with separate kinds.
    assert_equal "agreement", terms.kind
    assert_equal "agreed", terms.action
    assert_equal "acknowledgment", privacy.kind
    assert_equal "acknowledged", privacy.action
  end

  test "capture stores the resolved assertion text, not an I18n key" do
    receipt = capture_clickwrap(:driver_declaration, actor: @user, subject: create_withdrawal,
                                                     answers: { non_professional_driver: "1" })

    statement = receipt.statements.first
    assert_equal "I declare that I drive privately and not as a professional driver.",
                 statement.assertion_text
    assert_equal "en", statement.assertion_locale
  end

  test "capture binds the exact document versions and digests" do
    receipt = capture_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })

    terms_document = receipt.documents.find { |document| document.document_key == "terms" }
    version = Clickwrap::Document.find_by(document_key: "terms").current_version

    assert_equal version.version_label, terms_document.version_label
    assert_equal version.content_digest, terms_document.source_content_digest
    assert terms_document.still_matches_stored_version?
  end

  test "capture updates the current-state projection" do
    capture_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })

    assert @user.clickwraps.agreed_to?(:terms)
    assert @user.clickwraps.acknowledged?(:privacy_notice)
    assert @user.clickwraps.current_for?(:signup)
  end

  test "a required statement left unanswered is refused" do
    error = assert_raises(Clickwrap::AnswerInvalid) do
      capture_clickwrap(:signup, actor: @user, answers: { terms: "1" })
    end

    assert_equal "privacy_notice", error.statement_key
    assert_equal :missing_answer, error.reason
  end

  # --- Optional consent -------------------------------------------------------

  test "an optional consent left unselected creates no grant at all" do
    receipt = capture_clickwrap(:marketing_preferences, actor: @user, answers: {})

    # Silence is not an affirmative refusal, and this gem will not record it as
    # one. The option was offered and not taken; that is all that happened.
    assert_empty receipt.statements
    assert_not @user.clickwraps.consented_to?(:product_updates)
    assert_nil @user.clickwraps.consent(:product_updates)
  end

  test "each optional consent purpose is granted separately" do
    capture_clickwrap(:marketing_preferences, actor: @user, answers: { product_updates: "1" })

    assert @user.clickwraps.consented_to?(:product_updates)
    assert_not @user.clickwraps.consented_to?(:partner_offers)
  end

  test "an explicit no is recorded as declined rather than as absence" do
    capture_clickwrap(:research_contact, actor: @user, answers: { research_contact: "no" })

    state = @user.clickwraps.consent(:research_contact)
    assert_equal "declined", state.state
    assert_not @user.clickwraps.consented_to?(:research_contact)
  end

  test "an answer that was never offered as a choice is refused" do
    assert_raises(Clickwrap::AnswerInvalid) do
      capture_clickwrap(:research_contact, actor: @user, answers: { research_contact: "maybe" })
    end
  end

  # --- Atomicity --------------------------------------------------------------

  test "capture_and! commits the evidence and the protected action together" do
    withdrawal = create_withdrawal(user: @user)

    receipt = capture_clickwrap_and(:withdrawal_authorization, actor: @user, subject: withdrawal,
                                                               answers: default_withdrawal_answers) do |pending|
      withdrawal.submit!(authorized_by_clickwrap_event: pending.event_id)
    end

    assert_equal "submitted", withdrawal.reload.state
    assert_equal receipt.event_id, withdrawal.authorized_by_clickwrap_event
    assert Clickwrap::Event.exists?(id: receipt.event_id)
  end

  test "when the protected action raises, the evidence rolls back with it" do
    withdrawal = create_withdrawal(user: @user)

    assert_no_difference -> { Clickwrap::Event.count } do
      assert_raises(RuntimeError) do
        capture_clickwrap_and(:withdrawal_authorization, actor: @user, subject: withdrawal,
                                                         answers: default_withdrawal_answers) do
          raise "the domain action failed"
        end
      end
    end

    assert_equal "draft", withdrawal.reload.state
  end

  test "when the evidence write fails, the protected action rolls back with it" do
    withdrawal = create_withdrawal(user: @user)

    # This is the failure mode the gem exists to eliminate: an account, a payout,
    # or a provider handoff that succeeded while its evidence quietly did not.
    Clickwrap::Testing.fail_next_event_write do
      assert_raises(Clickwrap::EventWriteFailed) do
        capture_clickwrap_and(:withdrawal_authorization, actor: @user, subject: withdrawal,
                                                         answers: default_withdrawal_answers) do |pending|
          withdrawal.submit!(authorized_by_clickwrap_event: pending.event_id)
        end
      end
    end

    assert_equal "draft", withdrawal.reload.state
    assert_no_clickwrap_event :withdrawal_authorization, actor: @user
  end

  test "the pending receipt refuses to export or verify before commit" do
    withdrawal = create_withdrawal(user: @user)
    captured = nil

    capture_clickwrap_and(:withdrawal_authorization, actor: @user, subject: withdrawal,
                                                     answers: default_withdrawal_answers) do |pending|
      captured = pending
      assert pending.event_id.present?
      assert_raises(Clickwrap::ReceiptNotCommitted) { pending.to_canonical_json }
      assert_raises(Clickwrap::ReceiptNotCommitted) { pending.verify }
      withdrawal.submit!(authorized_by_clickwrap_event: pending.event_id)
    end

    assert_not captured.committed?
  end

  test "the protected outcome is recorded from the host's configured lambda" do
    withdrawal = create_withdrawal(user: @user)

    receipt = capture_clickwrap_and(:withdrawal_authorization, actor: @user, subject: withdrawal,
                                                               answers: default_withdrawal_answers) do |pending|
      withdrawal.submit!(authorized_by_clickwrap_event: pending.event_id)
    end

    outcome = receipt.event.reload.protected_outcome

    # Never inferred from "the block returned without raising" — that tells us
    # the block returned without raising, not what the host method meant.
    assert_equal "submitted", outcome["action"]
    assert_equal withdrawal.to_gid.to_s, outcome["reference"]
    assert_equal withdrawal.evidence_fingerprint, outcome["fingerprint"]
  end

  # --- Idempotency and replay -------------------------------------------------

  test "resubmitting the same presentation returns the original receipt without re-running the action" do
    withdrawal = create_withdrawal(user: @user)
    presentation = present_clickwrap(:withdrawal_authorization, actor: @user, subject: withdrawal)
    runs = 0

    submission = submission_for(presentation, default_withdrawal_answers)

    first = Clickwrap.capture_and!(:withdrawal_authorization, actor: @user,
                                                              subject: withdrawal,
                                                              submission: submission) { runs += 1 }

    second = Clickwrap.capture_and!(:withdrawal_authorization, actor: @user,
                                                               subject: withdrawal,
                                                               submission: submission) { runs += 1 }

    assert_equal first.event_id, second.event_id
    assert_equal 1, runs, "the protected action must not run a second time"
    assert_equal 1, Clickwrap::Event.captures.for_policy("withdrawal_authorization").count
    assert_equal 1, Clickwrap::Event.for_policy("withdrawal_authorization")
                                    .where(event_type: "consumption").count
  end

  test "reusing a presentation with different answers is rejected as a replay" do
    presentation = present_clickwrap(:research_contact, actor: @user)

    Clickwrap.capture!(:research_contact, actor: @user,
                                          submission: submission_for(presentation, { research_contact: "yes" }))

    assert_raises(Clickwrap::ReplayRejected) do
      Clickwrap.capture!(:research_contact, actor: @user,
                                            submission: submission_for(presentation, { research_contact: "no" }))
    end
  end

  # --- Presentation binding ---------------------------------------------------

  test "a presentation issued to another actor is rejected" do
    other = create_user
    presentation = present_clickwrap(:signup, actor: other)

    error = assert_raises(Clickwrap::PresentationInvalid) do
      Clickwrap.capture!(:signup, actor: @user,
                                  submission: submission_for(presentation, { terms: "1", privacy_notice: "1" }))
    end

    assert_equal :presentation_actor_mismatch, error.result.error
  end

  test "a presentation issued for another subject is rejected" do
    withdrawal = create_withdrawal(user: @user)
    other_withdrawal = create_withdrawal(user: @user)
    presentation = present_clickwrap(:withdrawal_authorization, actor: @user, subject: withdrawal)

    error = assert_raises(Clickwrap::PresentationInvalid) do
      Clickwrap.capture!(:withdrawal_authorization,
                         actor: @user,
                         subject: other_withdrawal,
                         submission: submission_for(presentation, default_withdrawal_answers))
    end

    assert_equal :presentation_subject_mismatch, error.result.error
  end

  test "an expired presentation is rejected" do
    presentation = expired_clickwrap_presentation_for(:signup, actor: @user)

    error = assert_raises(Clickwrap::PresentationExpired) do
      Clickwrap.capture!(:signup, actor: @user,
                                  submission: submission_for(presentation, { terms: "1", privacy_notice: "1" }))
    end

    assert_equal :presentation_expired, error.result.error
  end

  test "a tampered presentation token is rejected" do
    presentation = present_clickwrap(:signup, actor: @user)
    tampered = "#{presentation.token[0..-4]}abc"

    assert_raises(Clickwrap::PresentationInvalid) do
      Clickwrap.capture!(:signup, actor: @user,
                                  submission: Clickwrap::Submission.new(presentation_token: tampered,
                                                                        answers: { "terms" => "1" }))
    end
  end

  test "a presentation for one policy cannot be captured as another" do
    presentation = present_clickwrap(:signup, actor: @user)

    error = assert_raises(Clickwrap::PresentationInvalid) do
      Clickwrap.capture!(:current_terms, actor: @user,
                                         submission: submission_for(presentation, { terms: "1" }))
    end

    assert_equal :presentation_policy_mismatch, error.result.error
  end

  test "a deploy that publishes a new document version between render and submit is refused" do
    presentation = present_clickwrap(:signup, actor: @user)
    publish_new_document_version!(:terms, version: "2026-09-01")
    Clickwrap::Document.find_by(document_key: "terms").versions.find_by(version_label: "2026-08-15")
                       .update_columns(content: "rewritten bytes")

    # The server must never record a version the person was not offered.
    error = assert_raises(Clickwrap::PresentationInvalid) do
      Clickwrap.capture!(:signup, actor: @user,
                                  submission: submission_for(presentation, { terms: "1", privacy_notice: "1" }))
    end

    assert_equal :document_digest_mismatch, error.result.error
  end

  # --- What a submission may not carry ---------------------------------------

  test "a submission cannot choose the policy, a document version, or retention" do
    %w[policy policy_revision document_version retain_until ip_address browser_user_agent].each do |smuggled|
      assert_raises(Clickwrap::SubmissionInvalid) do
        Clickwrap::Submission.new(presentation_token: "x", answers: { smuggled => "anything" })
      end
    end
  end

  test "a submission cannot answer a statement the presentation never offered" do
    presentation = present_clickwrap(:signup, actor: @user)

    assert_raises(Clickwrap::SubmissionInvalid) do
      Clickwrap.capture!(:signup, actor: @user,
                                  submission: submission_for(presentation,
                                                             { terms: "1", privacy_notice: "1",
                                                               something_else: "1" }))
    end
  end

  private

  def default_withdrawal_answers
    { withdrawal_requirements: "1", ride_exclusivity: "1", withdrawal: "1" }
  end
end
