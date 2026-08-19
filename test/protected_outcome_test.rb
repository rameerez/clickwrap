# frozen_string_literal: true

require "test_helper"

class ProtectedOutcomeTest < ActiveSupport::TestCase
  setup do
    @user = create_user
    @withdrawal = create_withdrawal(user: @user)
  end

  test "the helper records and fingerprints the complete exact result" do
    outcome = Clickwrap.protected_outcome(
      action: :submitted,
      record: @withdrawal,
      state: :submitted,
      facts: { amount_in_cents: 25_000, currency: "EUR" }
    )

    assert_equal "submitted", outcome["action"]
    assert_equal @withdrawal.to_gid.to_s, outcome["reference"]
    assert_equal "submitted", outcome["state"]
    assert_equal({ "amount_in_cents" => 25_000, "currency" => "EUR" }, outcome["facts"])
    assert_equal outcome, Clickwrap::ProtectedOutcome.validate!(outcome)
  end

  test "a fingerprint copied onto changed facts is refused" do
    outcome = Clickwrap.protected_outcome(
      action: :submitted,
      record: @withdrawal,
      facts: { amount_in_cents: 25_000 }
    ).deep_dup
    outcome["facts"]["amount_in_cents"] = 99_000

    error = assert_raises(Clickwrap::DefinitionError) do
      Clickwrap::ProtectedOutcome.validate!(outcome)
    end

    assert_match(/fingerprint does not match/, error.message)
  end

  test "a protected outcome refuses an unsaved result and empty facts" do
    assert_raises(ArgumentError) do
      Clickwrap.protected_outcome(action: :created, record: Withdrawal.new, facts: { id: "pending" })
    end

    assert_raises(ArgumentError) do
      Clickwrap.protected_outcome(action: :submitted, record: @withdrawal, facts: {})
    end
  end

  test "plain capture creates no fictional protected outcome" do
    receipt = submit_clickwrap(
      :withdrawal_authorization,
      actor: @user,
      subject: @withdrawal,
      answers: { withdrawal_requirements: "1", coverage_exclusivity: "1", withdrawal: "1" }
    )

    assert_nil receipt.event.protected_outcome
    assert_equal "draft", @withdrawal.reload.state
  end

  test "a malformed outcome rolls the protected domain action back" do
    Clickwrap.policy :malformed_outcome do
      authorize :withdrawal,
                document: :withdrawal_requirements,
                statement: "I authorize this malformed-outcome test.",
                valid_for: 10.minutes,
                protected_outcome_version: "malformed-v1",
                record_protected_outcome_with: ->(_result) { { action: :pretended } }
      retain_with :regulated_evidence
    end

    presentation = present_clickwrap(:malformed_outcome, actor: @user, subject: @withdrawal)

    assert_raises(Clickwrap::DefinitionError) do
      Clickwrap.capture_and!(
        :malformed_outcome,
        actor: @user,
        subject: @withdrawal,
        submission: submission_for(presentation, { withdrawal: "1" })
      ) do
        @withdrawal.update!(state: "submitted")
        @withdrawal
      end
    end

    assert_equal "draft", @withdrawal.reload.state
    assert_no_clickwrap_event :malformed_outcome, actor: @user
  end
end
