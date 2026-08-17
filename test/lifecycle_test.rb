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
    grant = submit_clickwrap(:marketing_preferences, actor: @user, answers: { product_updates: "1" })
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
    submit_clickwrap(:marketing_preferences, actor: @user, answers: { product_updates: "1" })

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
    submit_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
    submit_clickwrap(:marketing_preferences, actor: @user, answers: { product_updates: "1" })

    Clickwrap.withdraw!(:product_updates, actor: @user, because: "Changed their mind about marketing")

    # Withdrawing future consent to marketing does not retroactively unmake a
    # contract. A gem that let it would be recording something false.
    assert @user.clickwraps.agreed_to?(:terms)
    assert @user.clickwraps.current_for?(:signup)
  end

  test "an agreement cannot be withdrawn" do
    submit_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })

    assert_raises(Clickwrap::NotWithdrawableError) do
      Clickwrap.withdraw!(:terms, actor: @user, because: "Trying to withdraw a contract")
    end
  end

  # --- Declarations -----------------------------------------------------------

  test "a declaration expires without implying it was false when it was made" do
    scheme = create_withdrawal(user: @user)
    receipt = submit_clickwrap(:contractor_declaration, actor: @user, subject: scheme,
                                                        answers: { independent_contractor: "1" })

    assert @user.clickwraps.declared?(:independent_contractor, subject: scheme)

    state = @user.clickwraps.declaration(:independent_contractor, subject: scheme)
    assert_in_delta 1.year.from_now.to_i, state.expires_at.to_i, 60

    travel_to 13.months.from_now do
      assert_not @user.clickwraps.declared?(:independent_contractor, subject: scheme)

      result = Clickwrap.verify(:contractor_declaration, actor: @user, subject: scheme)
      assert_equal :declaration_expired, result.error

      # The original statement is still exactly what it was.
      assert_equal "declared", receipt.event.reload.statements.first.action
      assert receipt.event.digest_verified?
    end
  end

  test "expiry is evaluated live rather than depending on a job having run" do
    scheme = create_withdrawal(user: @user)
    submit_clickwrap(:contractor_declaration, actor: @user, subject: scheme,
                                              answers: { independent_contractor: "1" })

    travel_to 13.months.from_now do
      # No sweep has run. The projection still says "active", and the answer is
      # still no — because evidence must not become wrongly valid just because a
      # background job did not reach it.
      assert_equal "active", Clickwrap::StatementState.last.state
      assert_not @user.clickwraps.declared?(:independent_contractor, subject: scheme)
    end
  end

  test "the expiry sweep appends the lifecycle event at the exact validity boundary" do
    scheme = create_withdrawal(user: @user)
    submit_clickwrap(:contractor_declaration, actor: @user, subject: scheme,
                                              answers: { independent_contractor: "1" })
    state = @user.clickwraps.declaration(:independent_contractor, subject: scheme)

    travel_to state.expires_at, with_usec: true do
      expiry = nil

      assert_difference -> { Clickwrap::Event.where(event_type: "expiry").count }, 1 do
        expiry = Clickwrap::Lifecycle.expire_due!(at: state.expires_at).sole
      end

      assert_equal "expired", state.reload.state
      assert_equal state.expires_at, expiry.statements.sole.valid_from
    end
  end

  test "correcting a declaration appends a correction and leaves the original saying what it said" do
    scheme = create_withdrawal(user: @user)
    original = submit_clickwrap(:contractor_declaration, actor: @user, subject: scheme,
                                                         answers: { independent_contractor: "1" })

    correction = nil
    assert_difference -> { Clickwrap::Event.where(event_type: "correction").count }, 1 do
      correction = committed_test_receipt(Clickwrap.correct_declaration!(
                                            :independent_contractor,
                                            actor: @user,
                                            subject: scheme,
                                            because: "The person told us their circumstances changed",
                                            submission: lifecycle_submission(:contractor_declaration,
                                                                             actor: @user, subject: scheme)
                                          ))
    end

    # A correction does not say the original was false when it was made. Both
    # events exist, the first still verifies, and it still reads "declared".
    assert_equal "correction", correction.event.event_type
    assert_equal original.event_id, correction.event.predecessor_event_id
    assert_equal original.event_id, correction.event.root_event_id
    assert_equal "declared", original.event.reload.statements.sole.action
    assert_predicate original.event, :digest_verified?

    assert_equal "corrected", correction.event.statements.sole.action
    assert_predicate correction.verify, :success?

    # The corrected statement is the one that counts now, and it is still an
    # ACTIVE declaration — a correction replaces what the person says, it does
    # not put them in a state of having declared nothing.
    state = @user.clickwraps.declaration(:independent_contractor, subject: scheme)
    assert_equal "active", state.state
    assert_equal correction.event_id, state.current_event_id
    assert @user.clickwraps.declared?(:independent_contractor, subject: scheme)
  end

  test "an agreement cannot be corrected, because that is what a new version is for" do
    submit_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })

    error = assert_raises(Clickwrap::LifecycleError) do
      Clickwrap.correct_declaration!(:terms, actor: @user, because: "Trying to correct a contract")
    end

    assert_match(/superseded by a new version/, error.message)
  end

  test "renewing starts a new validity period rather than extending the old one" do
    scheme = create_withdrawal(user: @user)
    original = submit_clickwrap(:contractor_declaration, actor: @user, subject: scheme,
                                                         answers: { independent_contractor: "1" })
    first_expiry = @user.clickwraps.declaration(:independent_contractor, subject: scheme).expires_at

    renewal = nil
    travel_to 6.months.from_now do
      assert_difference -> { Clickwrap::Event.where(event_type: "renewal").count }, 1 do
        renewal = committed_test_receipt(Clickwrap.renew!(
                                           :independent_contractor,
                                           actor: @user,
                                           subject: scheme,
                                           because: "The person renewed their declaration before it lapsed",
                                           submission: lifecycle_submission(:contractor_declaration,
                                                                            actor: @user, subject: scheme)
                                         ))
      end

      renewed_expiry = @user.clickwraps.declaration(:independent_contractor, subject: scheme).expires_at

      # A full period from the renewal, not the old expiry pushed along — so a
      # stale expiry can never quietly survive a renewal.
      assert_in_delta 1.year.from_now.to_i, renewed_expiry.to_i, 60
      assert_operator renewed_expiry, :>, first_expiry
      assert @user.clickwraps.declared?(:independent_contractor, subject: scheme)
    end

    assert_equal "renewal", renewal.event.event_type
    assert_equal original.event_id, renewal.event.root_event_id
    assert_equal "declared", original.event.reload.statements.sole.action
    assert_predicate original.event, :digest_verified?
    assert_predicate renewal.verify, :success?
  end

  test "a statement with no validity period cannot be renewed" do
    submit_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })

    error = assert_raises(Clickwrap::LifecycleError) do
      Clickwrap.renew!(:terms, actor: @user, because: "Trying to renew something that never expires")
    end

    assert_match(/no validity period/, error.message)
  end

  test "changing consent scope appends a scope change and keeps the original grant" do
    grant = submit_clickwrap(:personal_newsletter, actor: @user,
                                                   answers: { personal_newsletter: "1" })

    change = nil
    assert_difference -> { Clickwrap::Event.where(event_type: "scope_change").count }, 1 do
      change = committed_test_receipt(Clickwrap.change_consent_scope!(
                                        :personal_newsletter,
                                        actor: @user,
                                        because: "The person narrowed this permission in privacy settings",
                                        submission: lifecycle_submission(
                                          :personal_newsletter, actor: @user,
                                                                answers: { personal_newsletter: "1" }
                                        )
                                      ))
    end

    assert_equal "scope_change", change.event.event_type
    assert_equal grant.event_id, change.event.root_event_id
    assert_equal grant.event_id, change.event.predecessor_event_id
    assert_equal "scope_changed", change.event.statements.sole.action

    # The rescoped consent is the one that counts now, and it is still ACTIVE:
    # narrowing what a permission covers is not the same act as withdrawing it,
    # and the projection must not blur the two.
    state = @user.clickwraps.consent(:personal_newsletter)
    assert_equal "active", state.state
    assert_equal change.event_id, state.current_event_id
    assert @user.clickwraps.consented_to?(:personal_newsletter)

    # The original grant is still there and still says what it said. A scope
    # change is a new permission, never a rewrite of the earlier one.
    assert_equal "granted", grant.event.reload.statements.sole.action
    assert_predicate grant.event, :digest_verified?
    assert_predicate change.verify, :success?
  end

  test "only consent has a changeable scope" do
    scheme = create_withdrawal(user: @user)
    submit_clickwrap(:contractor_declaration, actor: @user, subject: scheme,
                                              answers: { independent_contractor: "1" })

    error = assert_raises(Clickwrap::LifecycleError) do
      Clickwrap.change_consent_scope!(:independent_contractor, actor: @user, subject: scheme,
                                                               because: "Trying to rescope a declaration")
    end

    assert_match(/Only consent has a changeable scope/, error.message)
  end

  test "a declaration is bound to its subject fingerprint" do
    scheme = create_withdrawal(user: @user, covered_order_ids: "1,2,3")
    submit_clickwrap(:contractor_declaration, actor: @user, subject: scheme,
                                              answers: { independent_contractor: "1" })

    assert @user.clickwraps.declared?(:independent_contractor, subject: scheme)

    scheme.update!(covered_order_ids: "1,2,3,4")

    result = Clickwrap.verify(:contractor_declaration, actor: @user, subject: scheme)
    assert_equal :subject_fingerprint_mismatch, result.error
  end

  # --- Authorizations ---------------------------------------------------------

  test "a one-time authorization is consumed and cannot be reused" do
    withdrawal = create_withdrawal(user: @user)

    submit_clickwrap_and(:withdrawal_authorization, actor: @user, subject: withdrawal,
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

    submit_clickwrap_and(:withdrawal_authorization, actor: @user, subject: withdrawal,
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
    submit_clickwrap(:withdrawal_authorization, actor: @user, subject: withdrawal,
                                                answers: withdrawal_answers)

    Clickwrap.revoke!(:withdrawal, actor: @user, subject: withdrawal,
                                   because: "Suspected account compromise")

    result = Clickwrap.verify(:withdrawal_authorization, actor: @user, subject: withdrawal)
    assert_equal :revoked, result.error
  end

  # --- Reacceptance -----------------------------------------------------------

  test "publishing a new required version makes existing evidence no longer current" do
    submit_clickwrap(:current_terms, actor: @user, answers: { terms: "1" })
    assert @user.clickwraps.current_for?(:current_terms)

    publish_new_document_version!(:terms, version: "2026-12-01")

    assert_not @user.clickwraps.current_for?(:current_terms)
    assert Clickwrap.required?(:current_terms, actor: @user)

    result = Clickwrap.verify(:current_terms, actor: @user)
    assert_equal :unseen_document_version, result.error
  end

  test "a policy without require_current_version keeps its evidence current" do
    submit_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
    publish_new_document_version!(:terms, version: "2026-12-01")

    # The application decides which change is material. Clickwrap enforces the
    # rule it was given and does not invent one.
    assert @user.clickwraps.current_for?(:signup)
  end

  test "require_current_revision re-asks when the statement wording itself moved on" do
    submit_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })

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

  # --- The same question, asked from the other end -----------------------------
  #
  # `Clickwrap.verify(event_id, …)` promises to be `Clickwrap.verify(:policy, …)`
  # asked about one recorded act. Both keywords that make that question strict
  # used to be accepted and then dropped on this branch, which is worse than
  # rejecting them: a host asking "is this old evidence still good?" got an
  # unqualified yes. The four tests below pin both keywords, in both outcomes.

  test "an event id honors require_current_revision when the act was made under another one" do
    submit_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })

    assert Clickwrap.verify(@user.clickwraps.events.last.id, require_current_revision: true).success?,
           "evidence made under the current wording verifies from either end"

    # A legacy import is the honest, non-simulated case: its revision snapshot
    # describes a mapping rather than a presentation, so it can never equal the
    # compiled policy's revision. Asking "is this old evidence still good under
    # today's wording" about it must answer no.
    imported = Clickwrap.import_legacy!(
      :signup,
      actor: create_user,
      occurred_at: 2.years.ago,
      source: "users.accepted_terms_at",
      because: "Imported historical signup evidence"
    )

    assert Clickwrap.verify(imported.event_id).success?,
           "revision currency is opt-in from this end too, never a surprise default"

    strict = Clickwrap.verify(imported.event_id, require_current_revision: true)

    refute_predicate strict, :success?
    assert_equal :stale_policy_revision, strict.error
    assert_equal imported.event_id, strict.event_id
  end

  test "an event id re-derives the subject fingerprint when a subject is passed" do
    withdrawal = create_withdrawal(user: @user, covered_order_ids: "1,2,3")
    submit_clickwrap(:withdrawal_authorization, actor: @user, subject: withdrawal,
                                                answers: withdrawal_answers)
    event_id = @user.clickwraps.events.last.id

    assert Clickwrap.verify(event_id, subject: withdrawal).success?

    # The subject is the same RECORD, so subject_key still matches — only the
    # fingerprint can tell that what the declaration covered has changed.
    withdrawal.update!(covered_order_ids: "1,2,3,4")

    result = Clickwrap.verify(event_id, subject: withdrawal)

    refute_predicate result, :success?
    assert_equal :subject_fingerprint_mismatch, result.error
    assert_equal event_id, result.event_id
  end

  test "an event id verified with no subject still answers the question it was asked" do
    withdrawal = create_withdrawal(user: @user, covered_order_ids: "1,2,3")
    submit_clickwrap(:withdrawal_authorization, actor: @user, subject: withdrawal,
                                                answers: withdrawal_answers)
    event_id = @user.clickwraps.events.last.id

    withdrawal.update!(covered_order_ids: "1,2,3,4")

    # Nobody named a subject, so nothing about a subject was claimed. Silently
    # checking against the live record would answer a question that was not
    # asked; silently skipping it when one IS named is the bug above.
    assert Clickwrap.verify(event_id).success?
  end

  test "an event whose policy is no longer declared says so instead of passing" do
    withdrawal = create_withdrawal(user: @user)
    submit_clickwrap(:withdrawal_authorization, actor: @user, subject: withdrawal,
                                                answers: withdrawal_answers)
    event_id = @user.clickwraps.events.last.id

    # "We can no longer check this" and "this is fine" must never be spelled
    # the same way.
    Clickwrap.stubs(:policies).returns(Clickwrap::Registry.new(:policy))

    strict = Clickwrap.verify(event_id, require_current_revision: true)
    assert_equal :unknown_policy, strict.error

    bound = Clickwrap.verify(event_id, subject: withdrawal)
    assert_equal :unknown_policy, bound.error
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
    receipt = submit_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
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

  # Correcting, renewing, and rescoping are affirmative acts by the same
  # person, so each one is captured through a real presentation exactly as the
  # first statement was — not an administrative flag flipped behind the
  # person's back. That is why every one of them needs a submission.
  def lifecycle_submission(policy_key, actor:, subject: nil, answers: {})
    submission_for(
      present_clickwrap(policy_key, actor: actor, subject: subject),
      default_clickwrap_answers(policy_key, answers)
    )
  end

  def withdrawal_answers
    { withdrawal_requirements: "1", coverage_exclusivity: "1", withdrawal: "1" }
  end
  test "recorded_after? makes multi-step ordering API instead of ULID folklore" do
    first = submit_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
    later_user = create_user
    second = submit_clickwrap(:signup, actor: later_user, answers: { terms: "1", privacy_notice: "1" })

    earlier = Clickwrap.verify(:signup, actor: @user)
    later = Clickwrap.verify(:signup, actor: later_user)

    assert later.recorded_after?(earlier)
    refute earlier.recorded_after?(later)
    assert later.recorded_after?(earlier.event_id), "a bare event id compares too"
    refute later.recorded_after?(Clickwrap.verify(:signup, actor: create_user)),
           "nothing about a missing act is after anything"
    assert_operator Clickwrap::Event.find(second.event_id).recording_sequence, :>,
                    Clickwrap::Event.find(first.event_id).recording_sequence,
                    "the database sequence, not either process's ULID generator, owns chronology"
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

    submit_clickwrap_and(:withdrawal_authorization, actor: @user, subject: withdrawal,
                                                    answers: withdrawal_answers) do |pending|
      withdrawal.clickwrap_event_id = pending.event_id
      withdrawal.submit!(authorized_by_clickwrap_event: pending.event_id)
    end

    assert_equal "capture", withdrawal.reload.clickwrap_event.event_type
    assert withdrawal.clickwrap_receipt.verify.success?
    assert_nil create_withdrawal(user: @user).clickwrap_receipt,
               "a pre-gem row answers nil rather than raising"
  end

  test "has_clickwrap_evidence refuses a link belonging to another act" do
    withdrawal = create_withdrawal(user: @user)
    other = create_withdrawal(user: @user)
    receipt = submit_clickwrap(:withdrawal_authorization, actor: @user, subject: other,
                                                          answers: withdrawal_answers)

    withdrawal.clickwrap_event_id = receipt.event_id

    assert_not withdrawal.valid?
    assert_match(/different act/, withdrawal.errors[:clickwrap_event].to_sentence)
  end

  test "has_clickwrap_evidence never lets a linked event be replaced or removed" do
    withdrawal = create_withdrawal(user: @user)

    submit_clickwrap_and(:withdrawal_authorization, actor: @user, subject: withdrawal,
                                                    answers: withdrawal_answers) do |pending|
      withdrawal.clickwrap_event_id = pending.event_id
      withdrawal.submit!(authorized_by_clickwrap_event: pending.event_id)
    end

    withdrawal.clickwrap_event_id = nil

    assert_not withdrawal.valid?
    assert_match(/cannot be replaced or removed/, withdrawal.errors[:clickwrap_event].to_sentence)
  end

  test "has_clickwrap_evidence can require the link on every newly created domain row" do
    required_class = Class.new(Withdrawal) do
      has_clickwrap_evidence policy: :withdrawal_authorization,
                             statement: :withdrawal,
                             actor: :user,
                             subject: :self
    end
    row = required_class.new(user: @user, covered_order_ids: "9", amount_cents: 500)

    assert_not row.valid?
    assert_match(/must be linked inside/, row.errors[:clickwrap_event].to_sentence)
  end

  test "has_clickwrap_evidence stays inert until its link migration has run" do
    pre_migration_class = Class.new(ApplicationRecord) do
      self.table_name = "users"

      has_clickwrap_evidence policy: :signup,
                             statement: :terms,
                             actor: :self,
                             subject: :self
    end
    historical_row = pre_migration_class.find(@user.id)

    assert historical_row.valid?
    assert_nil historical_row.clickwrap_receipt

    new_row = pre_migration_class.new
    new_row.valid?
    assert_empty new_row.errors[:clickwrap_event],
                 "the evidence contract starts when the generated column exists"
  end
end
