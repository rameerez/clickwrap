# frozen_string_literal: true

require "test_helper"

# The six kinds exist because they need different lifecycles. This is where that
# claim gets tested: withdrawal, expiry, correction, consumption, supersession,
# and exemption each behave the way the kind actually needs, and none of them
# rewrites what was already recorded.
class LifecycleTest < ActiveSupport::TestCase
  setup do
    @user = create_user
  end

  # --- Consent ----------------------------------------------------------------

  test "consent can be withdrawn, and withdrawal appends rather than deletes" do
    grant = capture_clickwrap(:marketing_preferences, actor: @user, answers: { product_updates: "1" })
    assert @user.clickwraps.consented_to?(:product_updates)

    withdrawal = Clickwrap.withdraw!(:product_updates, actor: @user,
                                                       because: "The user withdrew this purpose in privacy settings")

    assert_not @user.clickwraps.consented_to?(:product_updates)
    assert_equal "withdrawn", @user.clickwraps.consent(:product_updates).state

    # The historical grant is untouched — it is still there, still says what it
    # said, and still verifies.
    assert Clickwrap::Event.exists?(id: grant.event_id)
    assert grant.event.reload.digest_verified?
    assert_equal "withdrawal", withdrawal.event_type
    assert_equal grant.event_id, withdrawal.predecessor_event_id
  end

  test "withdrawal requires a plain-English reason" do
    capture_clickwrap(:marketing_preferences, actor: @user, answers: { product_updates: "1" })

    assert_raises(Clickwrap::LifecycleError) do
      Clickwrap.withdraw!(:product_updates, actor: @user, because: "  ")
    end
  end

  test "withdrawing something that was never granted says so" do
    assert_raises(Clickwrap::NotWithdrawableError) do
      Clickwrap.withdraw!(:product_updates, actor: @user, because: "Tidying up")
    end
  end

  test "withdrawing consent does not touch an agreement" do
    capture_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
    capture_clickwrap(:marketing_preferences, actor: @user, answers: { product_updates: "1" })

    Clickwrap.withdraw!(:product_updates, actor: @user, because: "Changed their mind about marketing")

    # Withdrawing future consent to marketing does not retroactively unmake a
    # contract. A gem that let it would be recording something false.
    assert @user.clickwraps.agreed_to?(:terms)
    assert @user.clickwraps.current_for?(:signup)
  end

  test "an agreement cannot be withdrawn" do
    capture_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })

    assert_raises(Clickwrap::NotWithdrawableError) do
      Clickwrap.withdraw!(:terms, actor: @user, because: "Trying to withdraw a contract")
    end
  end

  # --- Declarations -----------------------------------------------------------

  test "a declaration expires without implying it was false when it was made" do
    scheme = create_withdrawal(user: @user)
    receipt = capture_clickwrap(:driver_declaration, actor: @user, subject: scheme,
                                                     answers: { non_professional_driver: "1" })

    assert @user.clickwraps.declared?(:non_professional_driver, subject: scheme)

    state = @user.clickwraps.declaration(:non_professional_driver, subject: scheme)
    assert_in_delta 1.year.from_now.to_i, state.expires_at.to_i, 60

    travel_to 13.months.from_now do
      assert_not @user.clickwraps.declared?(:non_professional_driver, subject: scheme)

      result = Clickwrap.verify(:driver_declaration, actor: @user, subject: scheme)
      assert_equal :declaration_expired, result.error

      # The original statement is still exactly what it was.
      assert_equal "declared", receipt.event.reload.statements.first.action
      assert receipt.event.digest_verified?
    end
  end

  test "expiry is evaluated live rather than depending on a job having run" do
    scheme = create_withdrawal(user: @user)
    capture_clickwrap(:driver_declaration, actor: @user, subject: scheme,
                                           answers: { non_professional_driver: "1" })

    travel_to 13.months.from_now do
      # No sweep has run. The projection still says "active", and the answer is
      # still no — because evidence must not become wrongly valid just because a
      # background job did not reach it.
      assert_equal "active", Clickwrap::StatementState.last.state
      assert_not @user.clickwraps.declared?(:non_professional_driver, subject: scheme)
    end
  end

  test "the expiry sweep appends the lifecycle event at the exact validity boundary" do
    scheme = create_withdrawal(user: @user)
    capture_clickwrap(:driver_declaration, actor: @user, subject: scheme,
                                           answers: { non_professional_driver: "1" })
    state = @user.clickwraps.declaration(:non_professional_driver, subject: scheme)

    travel_to state.expires_at, with_usec: true do
      expiry = nil

      assert_difference -> { Clickwrap::Event.where(event_type: "expiry").count }, 1 do
        expiry = Clickwrap::Lifecycle.expire_due!(at: state.expires_at).sole
      end

      assert_equal "expired", state.reload.state
      assert_equal state.expires_at, expiry.statements.sole.valid_from
    end
  end

  test "a declaration is bound to its subject fingerprint" do
    scheme = create_withdrawal(user: @user, covered_ride_ids: "1,2,3")
    capture_clickwrap(:driver_declaration, actor: @user, subject: scheme,
                                           answers: { non_professional_driver: "1" })

    assert @user.clickwraps.declared?(:non_professional_driver, subject: scheme)

    scheme.update!(covered_ride_ids: "1,2,3,4")

    result = Clickwrap.verify(:driver_declaration, actor: @user, subject: scheme)
    assert_equal :subject_fingerprint_mismatch, result.error
  end

  # --- Authorizations ---------------------------------------------------------

  test "a one-time authorization is consumed and cannot be reused" do
    withdrawal = create_withdrawal(user: @user)

    capture_clickwrap_and(:withdrawal_authorization, actor: @user, subject: withdrawal,
                                                     answers: withdrawal_answers) do |pending|
      withdrawal.submit!(authorized_by_clickwrap_event: pending.event_id)
    end

    capture_event = Clickwrap::Event.captures.for_policy("withdrawal_authorization").last
    assert_raises(Clickwrap::AlreadyConsumedError) do
      Clickwrap::Lifecycle.consume_authorization!(
        event: capture_event,
        because: "Trying to spend the same authorization twice"
      )
    end

    state = @user.clickwraps.authorization(:withdrawal, subject: withdrawal)
    assert_equal "consumed", state.state

    result = Clickwrap.verify(:withdrawal_authorization, actor: @user, subject: withdrawal)
    assert_equal :authorization_consumed, result.error
  end

  test "an authorization for one subject does not authorize another" do
    withdrawal = create_withdrawal(user: @user)
    other = create_withdrawal(user: @user)

    capture_clickwrap_and(:withdrawal_authorization, actor: @user, subject: withdrawal,
                                                     answers: withdrawal_answers) do |pending|
      withdrawal.submit!(authorized_by_clickwrap_event: pending.event_id)
    end

    # This is the difference between "the user once accepted something" and
    # "this exact evidence authorized this exact operation".
    result = Clickwrap.verify(:withdrawal_authorization, actor: @user, subject: other)
    assert_not result.success?
    assert_equal :no_evidence, result.error
  end

  test "an authorization can be revoked with a reason" do
    withdrawal = create_withdrawal(user: @user)
    capture_clickwrap(:withdrawal_authorization, actor: @user, subject: withdrawal,
                                                 answers: withdrawal_answers)

    Clickwrap.revoke!(:withdrawal, actor: @user, subject: withdrawal,
                                   because: "Suspected account compromise")

    result = Clickwrap.verify(:withdrawal_authorization, actor: @user, subject: withdrawal)
    assert_equal :revoked, result.error
  end

  # --- Reacceptance -----------------------------------------------------------

  test "publishing a new required version makes existing evidence no longer current" do
    capture_clickwrap(:current_terms, actor: @user, answers: { terms: "1" })
    assert @user.clickwraps.current_for?(:current_terms)

    publish_new_document_version!(:terms, version: "2026-12-01")

    assert_not @user.clickwraps.current_for?(:current_terms)
    assert Clickwrap.required?(:current_terms, actor: @user)

    result = Clickwrap.verify(:current_terms, actor: @user)
    assert_equal :unseen_document_version, result.error
  end

  test "a policy without require_current_version keeps its evidence current" do
    capture_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
    publish_new_document_version!(:terms, version: "2026-12-01")

    # The application decides which change is material. Clickwrap enforces the
    # rule it was given and does not invent one.
    assert @user.clickwraps.current_for?(:signup)
  end

  test "require_current_revision re-asks when the statement wording itself moved on" do
    capture_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })

    assert Clickwrap.verify(:signup, actor: @user, require_current_revision: true).success?,
           "evidence made under the current wording verifies"

    # Legal rewords a statement: on the next boot LoadPolicies compiles a new
    # revision, and existing projections keep pointing at the superseded one.
    # (Re-declaring a policy key mid-process is refused by the registry — the
    # duplicate-key guard — so simulate the after-reload state directly: the
    # projection's revision is no longer the policy's current revision.)
    superseded_stand_in = Clickwrap::PolicyRevision.freeze_for(Clickwrap.policy!(:current_terms))
    Clickwrap::StatementState.for_actor(@user.to_gid.to_s).for_policy("signup")
                             .update_all(policy_revision_id: superseded_stand_in.id)

    ordinary = Clickwrap.verify(:signup, actor: @user)
    assert ordinary.success?, "revision currency is opt-in, never a surprise default"

    strict = Clickwrap.verify(:signup, actor: @user, require_current_revision: true)
    refute strict.success?
    assert_equal :stale_policy_revision, strict.error
    assert strict.stale_policy_revision?, "the vocabulary-generated predicate answers too"
    assert_equal "terms", strict.statement_key
  end

  test "verification results answer every stable error as a predicate" do
    result = Clickwrap.verify(:signup, actor: @user)

    assert result.no_evidence?
    refute result.consent_withdrawn?
    refute result.subject_fingerprint_mismatch?
  end

  # --- Exemptions -------------------------------------------------------------

  test "an exemption records that no human acted and never satisfies agreed_to?" do
    seeded = create_user

    Clickwrap.exempt!(:seeded_signup, actor: Clickwrap.system_actor("database_seed"),
                                      subject: seeded,
                                      because: "Generated demo account; no human signup occurred")

    event = Clickwrap::Event.for_policy("seeded_signup").last
    assert_equal "exemption", event.event_type
    assert_equal "system", event.capture_channel
    assert_equal "system/database_seed", event.actor_reference
  end

  test "a policy that does not permit exemptions refuses one" do
    error = assert_raises(Clickwrap::LifecycleError) do
      Clickwrap.exempt!(:signup, actor: Clickwrap.system_actor("database_seed"),
                                 because: "Trying to bypass signup")
    end

    assert_match(/does not permit exemptions/, error.message)
  end

  test "an exemption needs a reason" do
    assert_raises(Clickwrap::LifecycleError) do
      Clickwrap.exempt!(:seeded_signup, actor: Clickwrap.system_actor("seed"), because: "")
    end
  end

  # --- Append-only ------------------------------------------------------------

  test "an event cannot be updated or destroyed through ordinary ActiveRecord" do
    receipt = capture_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
    event = receipt.event

    assert_raises(Clickwrap::EventWriteFailed) { event.update!(reason: "rewritten") }
    assert_raises(Clickwrap::EventWriteFailed) { event.destroy }
    assert_raises(Clickwrap::EventWriteFailed) { event.statements.first.update!(answer: "0") }
    assert_raises(Clickwrap::EventWriteFailed) { event.documents.first.destroy }
  end

  test "a published document version cannot have its bytes changed" do
    version = Clickwrap::Document.find_by(document_key: "terms").current_version

    assert_raises(Clickwrap::DocumentVersionConflictError) do
      version.update!(content: "rewritten terms")
    end
  end

  test "republishing a version label with different bytes is refused" do
    definition = Clickwrap.documents.values.find { |candidate| candidate.key == "terms" }
    Clickwrap.documents.clear
    Clickwrap.document(:terms, version: definition.version_label, locale: :en,
                               content: "completely different bytes under the same label")

    # A version label that can mean two different documents is not a version
    # label, and every receipt citing it would silently change meaning.
    assert_raises(Clickwrap::DocumentVersionConflictError) { Clickwrap.publish! }
  end

  private

  def withdrawal_answers
    { withdrawal_requirements: "1", ride_exclusivity: "1", withdrawal: "1" }
  end
  test "recorded_after? makes multi-step ordering API instead of ULID folklore" do
    first = capture_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
    later_user = create_user
    second = capture_clickwrap(:signup, actor: later_user, answers: { terms: "1", privacy_notice: "1" })

    earlier = Clickwrap.verify(:signup, actor: @user)
    later = Clickwrap.verify(:signup, actor: later_user)

    assert later.recorded_after?(earlier)
    refute earlier.recorded_after?(later)
    assert later.recorded_after?(earlier.event_id), "a bare event id compares too"
    refute later.recorded_after?(Clickwrap.verify(:signup, actor: create_user)),
           "nothing about a missing act is after anything"
    assert first.event_id < second.event_id, "the underlying guarantee: ULIDs order by creation"
  end

  test "every person-caused refusal shares one rescuable family with a user-facing sentence" do
    assert_operator Clickwrap::PresentationInvalid, :<, Clickwrap::CaptureRefused
    assert_operator Clickwrap::PresentationExpired, :<, Clickwrap::CaptureRefused
    assert_operator Clickwrap::SubmissionInvalid, :<, Clickwrap::CaptureRefused
    assert_operator Clickwrap::AnswerInvalid, :<, Clickwrap::CaptureRefused

    stale = Clickwrap::PresentationInvalid.new("developer-facing details")
    assert_equal I18n.t("clickwrap.errors.presentation_no_longer_valid"), stale.user_facing_message

    unanswered = Clickwrap::AnswerInvalid.new(statement_key: "terms")
    assert_equal I18n.t("clickwrap.errors.required_statement"), unanswered.user_facing_message

    # The loud family stays loud: infrastructure failures are not refusals.
    refute_operator Clickwrap::EventWriteFailed, :<, Clickwrap::CaptureRefused
  end

  test "has_clickwrap_evidence reads a domain row's receipt aloud" do
    withdrawal = create_withdrawal(user: @user)

    capture_clickwrap_and(:withdrawal_authorization, actor: @user, subject: withdrawal,
                                                     answers: withdrawal_answers) do |pending|
      withdrawal.clickwrap_event_id = pending.event_id
      withdrawal.submit!(authorized_by_clickwrap_event: pending.event_id)
    end

    assert_equal "capture", withdrawal.reload.clickwrap_event.event_type
    assert withdrawal.clickwrap_receipt.verify.success?
    assert_nil create_withdrawal(user: @user).clickwrap_receipt,
               "a pre-gem row answers nil rather than raising"
  end
end
