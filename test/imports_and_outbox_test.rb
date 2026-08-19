# frozen_string_literal: true

require "test_helper"

class ImportsAndOutboxTest < ActiveSupport::TestCase
  setup { @user = create_user }

  # --- Import::Legacy ---------------------------------------------------------

  test "import_legacy! records occurred_at apart from recorded_at and lists unknowns" do
    happened = 3.years.ago.utc.change(usec: 0)

    result = Clickwrap.import_legacy!(
      :signup,
      actor: @user,
      occurred_at: happened,
      known: { document_version: "2026-08-15" },
      unknown: %i[exact_document_bytes presentation assertion submit_button_text request_evidence],
      because: "Imported from users.accepted_terms_at"
    )

    assert result.imported?, result.message
    event = result.event

    assert_equal "imported_legacy", event.event_type
    assert_equal "imported_provider", event.capture_channel
    assert_equal "imported_provider", event.attribution_method
    assert_nil event.presentation_manifest
    assert_nil event.presentation_manifest_digest
    assert_equal happened.to_i, event.occurred_at.to_i
    assert_operator event.recorded_at_by_server, :>, event.occurred_at

    provenance = event.provider_verification
    assert_equal %w[assertion exact_document_bytes presentation request_evidence submit_button_text],
                 provenance["unknown"]

    # The admission is inside the digested body too, not only beside it.
    assert(event.statements.all? { |s| s.assertion_text.include?("was not recorded") })
    assert event.digest_verified?

    # exact_document_bytes was listed unknown, so no document rows were invented.
    assert_empty event.documents

    # A migration preserves what the old database says happened, including its
    # unknowns — and it keeps ANSWERING it. The application answered "did this
    # person agree?" with yes the day before the migration; an import that
    # flipped that answer would force every existing user back through
    # re-acceptance, which is the history-rewriting imports exist to avoid.
    # What stays different is the evidence, not the answer: the event carries
    # `imported_provider` attribution and names its unknowns, and
    # `require_current_version` still sends people back when the documents
    # move on. (The first production host migration is where this semantic was settled.)
    assert_clickwrap_current :signup, actor: @user
    assert @user.clickwraps.agreed_to?(:terms)
    assert @user.clickwraps.acknowledged?(:privacy_notice)
    state = Clickwrap::StatementState.find_by(statement_key: "terms",
                                              actor_reference: @user.to_gid.to_s)
    assert_equal "imported_legacy", Clickwrap::Event.find(state.current_event_id).event_type

    # The actor's own records screen shows their imported history too — an
    # empty list would imply they never agreed to anything — and the imported
    # receipt verifies like any other.
    imported_receipt = @user.clickwraps.receipts.last
    assert_equal state.current_event_id, imported_receipt.event_id
    assert_clickwrap_receipt_verifies imported_receipt
  end

  test "import_legacy! is idempotent and dry-runnable" do
    happened = 2.years.ago.utc

    plan = Clickwrap.import_legacy!(:signup, actor: @user, occurred_at: happened,
                                             because: "x", dry_run: true, unknown: %w[presentation])
    assert plan.planned?
    assert_nil plan.event
    assert_equal 0, Clickwrap::Event.for_policy("signup").count

    first = Clickwrap.import_legacy!(:signup, actor: @user, occurred_at: happened, because: "x")
    again = Clickwrap.import_legacy!(:signup, actor: @user, occurred_at: happened, because: "x")

    assert first.imported?
    assert again.already_imported?
    assert_equal first.event.id, again.event.id
    assert_equal 1, Clickwrap::Event.for_policy("signup").count
  end

  test "import_legacy! refuses a missing reason or a missing occurred_at" do
    assert_raises(ArgumentError) do
      Clickwrap.import_legacy!(:signup, actor: @user, occurred_at: 1.year.ago, because: " ")
    end

    assert_raises(ArgumentError) do
      Clickwrap.import_legacy!(:signup, actor: @user, occurred_at: nil, because: "x")
    end
  end

  test "a late historical import cannot reactivate consent withdrawn after it occurred" do
    grant = submit_clickwrap(
      :marketing_preferences,
      actor: @user,
      answers: { product_updates: "1" }
    )
    withdrawal = Clickwrap.withdraw!(
      :product_updates,
      actor: @user,
      because: "The user withdrew this purpose"
    )

    imported = Clickwrap.import_legacy!(
      :marketing_preferences,
      actor: @user,
      occurred_at: 2.years.ago,
      statements: [:product_updates],
      source: "legacy_b2b_leads.marketing_accepted_at",
      because: "Imported a historical marketing flag"
    )

    assert imported.imported?
    refute @user.clickwraps.consented_to?(:product_updates)
    state = @user.clickwraps.consent(:product_updates)
    assert_equal "withdrawn", state.state
    assert_equal withdrawal.id, state.current_event_id

    Clickwrap::CurrentState.rebuild_for!(actor_reference: @user.clickwrap_actor_reference)
    state = @user.clickwraps.consent(:product_updates)
    assert_equal "withdrawn", state.state
    assert_equal withdrawal.id, state.current_event_id
    assert Clickwrap::Event.exists?(grant.event_id)
    assert Clickwrap::Event.exists?(imported.event_id)
  end

  test "legacy mappings never masquerade as the currently loaded policy revision" do
    imported = Clickwrap.import_legacy!(
      :signup,
      actor: @user,
      occurred_at: 2.years.ago,
      source: "users.accepted_terms_at",
      because: "Imported historical signup evidence"
    )

    assert @user.clickwraps.current_for?(:signup)
    result = Clickwrap.verify(:signup, actor: @user, require_current_revision: true)
    assert_equal :stale_policy_revision, result.error
    refute_equal Clickwrap.policy!(:signup).revision,
                 imported.event.policy_revision.revision_digest
    assert_equal "legacy_import_mapping",
                 imported.event.policy_revision.compiled_snapshot.fetch("revision_kind")
  end

  test "legacy evidence can be retained without authorizing current processing" do
    imported = Clickwrap.import_legacy!(
      :marketing_preferences,
      actor: @user,
      occurred_at: 2.years.ago,
      statements: [:product_updates],
      source: "legacy_required_bundled_checkbox",
      counts_as_current: false,
      because: "Retained for provenance; not used as current optional marketing permission"
    )

    assert imported.imported?
    refute imported.counts_as_current
    assert_equal false, imported.event.provider_verification.fetch("counts_as_current")
    refute @user.clickwraps.consented_to?(:product_updates)
    assert_nil @user.clickwraps.consent(:product_updates)
  end

  test "legacy import idempotency covers mapping provenance and current-state posture" do
    common = {
      actor: @user,
      occurred_at: 2.years.ago.change(usec: 0),
      statements: [:product_updates],
      because: "Imported historical marketing evidence"
    }

    first = Clickwrap.import_legacy!(
      :marketing_preferences,
      **common,
      source: "legacy_source_a",
      unknown: [:presentation],
      counts_as_current: false
    )
    corrected = Clickwrap.import_legacy!(
      :marketing_preferences,
      **common,
      source: "legacy_source_b",
      unknown: %i[presentation assertion],
      counts_as_current: true
    )

    refute_equal first.idempotency_key, corrected.idempotency_key
    refute_equal first.event_id, corrected.event_id
  end

  test "recorded_after uses the durable database sequence rather than ULID ordering" do
    # Freeze the clock AT the present instant (never an absolute date: documents
    # publish at boot time, so a fixed past moment predates every publication
    # the moment the wall clock passes it). Two captures on one frozen clock
    # share their timestamp, so any ordering between them must come from the
    # durable recording sequence.
    travel_to Time.current, with_usec: true do
      submit_clickwrap(:signup, actor: @user)
      submit_clickwrap(:current_terms, actor: @user)
    end

    signup = Clickwrap.verify(:signup, actor: @user)
    current_terms = Clickwrap.verify(:current_terms, actor: @user)
    signup_event = Clickwrap::Event.find(signup.event_id)
    current_terms_event = Clickwrap::Event.find(current_terms.event_id)

    assert_operator current_terms_event.recording_sequence, :>, signup_event.recording_sequence
    assert current_terms.recorded_after?(signup)
    refute signup.recorded_after?(current_terms)
  end

  # --- Import::ExternalReceipt ------------------------------------------------

  test "import_external_receipt! is idempotent on the provider event id" do
    first = Clickwrap.import_external_receipt!(
      :signup, actor: @user, provider_name: "stripe", provider_event_id: "acct_1",
               provider_receipt: { "service_agreement" => "full" },
               verified_with: :stripe_api, verified_at: Time.current
    )
    again = Clickwrap.import_external_receipt!(
      :signup, actor: @user, provider_name: "stripe", provider_event_id: "acct_1",
               provider_receipt: { "service_agreement" => "full" },
               verified_with: :stripe_api, verified_at: Time.current
    )

    assert_equal first.id, again.id
    assert_equal "external_receipt", first.event_type
    assert_equal "imported_provider", first.capture_channel
    assert_equal "imported_provider", first.attribution_method
    assert_nil first.presentation_manifest_digest
    assert_equal "checked_against_provider", first.provider_verification["state"]
    assert_not first.human_action?
    assert first.imported?
    assert first.digest_verified?
  end

  test "an unchecked provider receipt says so" do
    event = Clickwrap.import_external_receipt!(
      :signup, actor: @user, provider_name: "docusign", provider_event_id: "env_2",
               provider_receipt: nil, verified_with: nil, verified_at: nil
    )

    assert_equal "not_checked", event.provider_verification["state"]
  end

  # --- The outbox -------------------------------------------------------------

  test "authorize_external_action! commits evidence and a pending outbox row together" do
    withdrawal = create_withdrawal(user: @user)
    presentation = present_clickwrap(:withdrawal_authorization, actor: @user, subject: withdrawal)

    action = Clickwrap.authorize_external_action!(
      :withdrawal_authorization,
      actor: @user,
      subject: withdrawal,
      provider_name: "stripe",
      submission: submission_for(presentation, { withdrawal_requirements: "1",
                                                 coverage_exclusivity: "1", withdrawal: "1" })
    )

    assert_kind_of Clickwrap::ExternalAction, action
    assert action.pending?
    assert_equal "stripe", action.provider_name
    assert_includes action.idempotency_key, action.event_id
    assert_equal "capture", action.event.event_type
    assert_nil action.event.protected_outcome,
               "a pending provider call must not be recorded as a completed local outcome"

    action.record_provider_success_and_consume!({ "id" => "pi_1" })
    assert_equal "succeeded", action.reload.state

    # The one-time authorization was consumed, so it cannot authorize again.
    assert_not @user.clickwraps.authorized?(:withdrawal, subject: withdrawal)
  end

  test "the named local hook commits a domain projection with the evidence and pending action" do
    withdrawal = create_withdrawal(user: @user)
    presentation = present_clickwrap(:withdrawal_authorization, actor: @user, subject: withdrawal)
    observed = nil

    action = Clickwrap.authorize_external_action!(
      :withdrawal_authorization,
      actor: @user,
      subject: withdrawal,
      provider_name: "stripe",
      submission: submission_for(presentation, { withdrawal_requirements: "1",
                                                 coverage_exclusivity: "1", withdrawal: "1" })
    ) do |pending_action:, pending_receipt:|
      observed = [pending_action.id, pending_receipt.event_id]
      withdrawal.update!(clickwrap_event_id: pending_receipt.event_id)
    end

    assert_equal [action.id, action.event_id], observed
    assert_equal action.event_id, withdrawal.reload.clickwrap_event_id
  end

  test "the plain-English callback option is equivalent to the local transaction block" do
    withdrawal = create_withdrawal(user: @user)
    presentation = present_clickwrap(:withdrawal_authorization, actor: @user, subject: withdrawal)
    observed = nil
    callback = lambda do |pending_action:, pending_receipt:|
      observed = [pending_action.id, pending_receipt.event_id]
    end

    action = Clickwrap.authorize_external_action!(
      :withdrawal_authorization,
      actor: @user,
      subject: withdrawal,
      submission: submission_for(presentation, { withdrawal_requirements: "1",
                                                 coverage_exclusivity: "1", withdrawal: "1" }),
      after_pending_action_is_saved_inside_transaction: callback
    )

    assert_equal [action.id, action.event_id], observed
  end

  test "the external-action API refuses two competing local transaction hooks" do
    error = assert_raises(ArgumentError) do
      Clickwrap.authorize_external_action!(
        :withdrawal_authorization,
        after_pending_action_is_saved_inside_transaction: ->(**) {}
      ) { raise "the competing hook must never run" }
    end

    assert_includes error.message, "either after_pending_action_is_saved_inside_transaction: or a block"
  end

  test "a failing local hook rolls back the evidence, pending action, and domain projection" do
    withdrawal = create_withdrawal(user: @user)
    presentation = present_clickwrap(:withdrawal_authorization, actor: @user, subject: withdrawal)

    assert_raises(RuntimeError, match: /legacy projection failed/) do
      Clickwrap.authorize_external_action!(
        :withdrawal_authorization,
        actor: @user,
        subject: withdrawal,
        submission: submission_for(presentation, { withdrawal_requirements: "1",
                                                   coverage_exclusivity: "1", withdrawal: "1" })
      ) do |pending_receipt:, **|
        withdrawal.update!(clickwrap_event_id: pending_receipt.event_id)
        raise "legacy projection failed"
      end
    end

    assert_nil withdrawal.reload.clickwrap_event_id
    assert_equal 0, Clickwrap::ExternalAction.count
    assert_no_clickwrap_event :withdrawal_authorization, actor: @user
  end

  test "an idempotent external-action replay does not run the local hook again" do
    withdrawal = create_withdrawal(user: @user)
    presentation = present_clickwrap(:withdrawal_authorization, actor: @user, subject: withdrawal)
    submission = submission_for(presentation, { withdrawal_requirements: "1",
                                                coverage_exclusivity: "1", withdrawal: "1" })
    hook_calls = 0

    first = Clickwrap.authorize_external_action!(
      :withdrawal_authorization, actor: @user, subject: withdrawal, submission: submission
    ) do |**|
      hook_calls += 1
    end
    replay = Clickwrap.authorize_external_action!(
      :withdrawal_authorization, actor: @user, subject: withdrawal, submission: submission
    ) do |**|
      hook_calls += 1
    end

    assert_equal first.id, replay.id
    assert_equal 1, hook_calls
  end

  test "the local hook option rejects an ambiguous non-callable value" do
    error = assert_raises(ArgumentError) do
      Clickwrap::Services::AuthorizeExternalAction.new(
        policy: Clickwrap.policy!(:withdrawal_authorization),
        after_pending_action_is_saved_inside_transaction: :record_something
      )
    end

    assert_includes error.message, "must be callable"
    assert_includes error.message, "pending_action: and pending_receipt:"
  end

  test "an outbox-row failure rolls its authorization evidence back" do
    withdrawal = create_withdrawal(user: @user)
    presentation = present_clickwrap(:withdrawal_authorization, actor: @user, subject: withdrawal)
    Clickwrap::ExternalAction.stubs(:create!).raises(
      ActiveRecord::StatementInvalid.new("outbox write unavailable")
    )

    assert_raises(ActiveRecord::StatementInvalid) do
      Clickwrap.authorize_external_action!(
        :withdrawal_authorization,
        actor: @user,
        subject: withdrawal,
        provider_name: "stripe",
        submission: submission_for(
          presentation,
          { withdrawal_requirements: "1", coverage_exclusivity: "1", withdrawal: "1" }
        )
      )
    end

    assert_equal 0, Clickwrap::ExternalAction.count
    assert_no_clickwrap_event :withdrawal_authorization, actor: @user
    assert_not @user.clickwraps.authorized?(:withdrawal, subject: withdrawal)
  end

  test "a failed provider-outcome event rolls the outbox transition back and can be retried" do
    action, withdrawal = pending_external_action

    Clickwrap::Testing.fail_next_event_write do
      assert_raises(Clickwrap::EventWriteFailed) do
        action.record_provider_success_and_consume!("provider_id" => "pi_retryable")
      end
    end

    assert_equal "pending", action.reload.state
    assert_equal 0, action.attempt_count
    assert_nil action.provider_receipt
    assert_equal 0, Clickwrap::Event.where(event_type: %w[provider_outcome consumption]).count
    assert @user.clickwraps.authorized?(:withdrawal, subject: withdrawal)

    action.record_provider_success_and_consume!("provider_id" => "pi_retryable")

    assert_equal "succeeded", action.reload.state
    assert_equal 1, action.attempt_count
    assert_not @user.clickwraps.authorized?(:withdrawal, subject: withdrawal)
  end

  test "a repeated authorization request reuses the same outbox row and key" do
    withdrawal = create_withdrawal(user: @user)
    presentation = present_clickwrap(:withdrawal_authorization, actor: @user, subject: withdrawal)
    answers = { withdrawal_requirements: "1", coverage_exclusivity: "1", withdrawal: "1" }

    first = Clickwrap.authorize_external_action!(
      :withdrawal_authorization, actor: @user, subject: withdrawal,
                                 submission: submission_for(presentation, answers)
    )
    again = Clickwrap.authorize_external_action!(
      :withdrawal_authorization, actor: @user, subject: withdrawal,
                                 submission: submission_for(presentation, answers)
    )

    assert_equal first.id, again.id
    assert_equal first.idempotency_key, again.idempotency_key
    assert_equal 1, Clickwrap::ExternalAction.count
  end

  test "a repeated provider success is idempotent only when its evidence agrees" do
    action, withdrawal = pending_external_action

    action.record_provider_success_and_consume!("provider_id" => "pi_1")
    counts = [
      Clickwrap::Event.where(event_type: "provider_outcome").count,
      Clickwrap::Event.where(event_type: "consumption").count
    ]

    action.record_provider_success_and_consume!("provider_id" => "pi_1")
    assert_equal counts, [
      Clickwrap::Event.where(event_type: "provider_outcome").count,
      Clickwrap::Event.where(event_type: "consumption").count
    ]
    assert_not @user.clickwraps.authorized?(:withdrawal, subject: withdrawal)

    assert_raises(Clickwrap::ExternalActionAlreadyResolved) do
      action.record_provider_success_and_consume!("provider_id" => "pi_different")
    end
  end

  test "unknown provider observations remain reconcilable and each different attempt is appended" do
    action, = pending_external_action

    action.record_provider_outcome_unknown!(reason: "First request timed out")
    first_attempts = action.reload.attempt_count
    first_events = Clickwrap::Event.where(event_type: "provider_outcome").count

    action.record_provider_outcome_unknown!(reason: "Reconciliation endpoint timed out")

    assert_equal "unknown", action.reload.state
    assert_equal first_attempts + 1, action.attempt_count
    assert_equal first_events + 1, Clickwrap::Event.where(event_type: "provider_outcome").count

    action.record_provider_success_and_consume!("provider_id" => "pi_later")
    assert_equal "succeeded", action.reload.state
    assert action.resolved?
  end

  test "a late success for authorization A never consumes newer authorization B" do
    action_a, withdrawal = pending_external_action
    action_b = create_pending_external_action(withdrawal)

    current_before = @user.clickwraps.authorization(:withdrawal, subject: withdrawal)
    assert_equal action_b.event_id, current_before.root_event_id

    action_a.record_provider_success_and_consume!("provider_id" => "pi_a")

    current_after = @user.clickwraps.authorization(:withdrawal, subject: withdrawal)
    assert_equal action_b.event_id, current_after.root_event_id
    assert_equal "active", current_after.state
    assert @user.clickwraps.authorized?(:withdrawal, subject: withdrawal)

    consumption = Clickwrap::Event.where(event_type: "consumption", root_event_id: action_a.event_id).last
    assert consumption
    assert_equal action_a.event_id, consumption.predecessor_event_id
  end

  # --- Testing ---------------------------------------------------------------

  test "fail_next_event_write raises inside the capture transaction and rolls the action back" do
    withdrawal = create_withdrawal(user: @user)
    ran = false

    Clickwrap::Testing.fail_next_event_write do
      assert_raises(Clickwrap::EventWriteFailed) do
        submit_clickwrap_and(:withdrawal_authorization, actor: @user, subject: withdrawal,
                                                        answers: { withdrawal_requirements: "1",
                                                                   coverage_exclusivity: "1",
                                                                   withdrawal: "1" }) do
          ran = true
          withdrawal.update!(state: "submitted")
        end
      end
    end

    # The evidence is appended BEFORE the block runs, so a failed event write
    # means the protected action is never attempted at all. That is stronger
    # than rolling it back afterwards: the domain method does not run, so it
    # cannot have had a side effect outside the transaction either.
    assert_not ran, "the protected action must not run when the evidence write fails"
    assert_equal "draft", withdrawal.reload.state
    assert_no_clickwrap_event :withdrawal_authorization, actor: @user

    # Only the NEXT write is sabotaged, and the hook comes off afterwards.
    receipt = submit_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
    assert receipt.event_id.present?
  end

  test "fail_next_domain_write takes the evidence down with the domain write" do
    withdrawal = create_withdrawal(user: @user)

    Clickwrap::Testing.fail_next_domain_write do
      assert_raises(Clickwrap::Testing::DomainWriteFailed) do
        submit_clickwrap_and(:withdrawal_authorization, actor: @user, subject: withdrawal,
                                                        answers: { withdrawal_requirements: "1",
                                                                   coverage_exclusivity: "1",
                                                                   withdrawal: "1" }) do
          withdrawal.update!(state: "submitted")
        end
      end
    end

    assert_equal "draft", withdrawal.reload.state
    assert_no_clickwrap_event :withdrawal_authorization, actor: @user
  end

  test "freeze_time_at moves the server clock and restores it" do
    moment = Time.utc(2030, 1, 1, 12, 0, 0)
    before = Clickwrap.now

    Clickwrap::Testing.freeze_time_at(moment) do
      assert_equal moment, Clickwrap.now
      receipt = submit_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
      assert_equal moment.to_i, receipt.event.recorded_at_by_server.to_i
    end

    assert_operator Clickwrap.now, :>=, before
    assert_not_equal moment, Clickwrap.now
  end

  test "reset! is a no-op when nothing was installed" do
    Clickwrap::Testing.reset!
    Clickwrap::Testing.reset!
    receipt = submit_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
    assert receipt.event_id.present?
  end

  # --- TestHelpers ------------------------------------------------------------

  test "the expired presentation fails the server's own expiry check" do
    presentation = expired_clickwrap_presentation_for(:signup, actor: @user)

    error = assert_raises(Clickwrap::PresentationExpired) do
      Clickwrap.capture!(:signup, actor: @user,
                                  submission: submission_for(presentation,
                                                             { terms: "1", privacy_notice: "1" }))
    end

    assert_equal :presentation_expired, error.result.error
  end

  test "the stale token is rejected for its policy revision" do
    token = stale_clickwrap_token_for(:signup, actor: @user)
    submission = Clickwrap::Submission.new(presentation_token: token,
                                           answers: { "terms" => "1", "privacy_notice" => "1" })

    error = assert_raises(Clickwrap::PresentationInvalid) do
      Clickwrap.capture!(:signup, actor: @user, submission: submission)
    end

    assert_equal :stale_policy_revision, error.result.error
  end

  test "another actor's token is rejected" do
    other = create_user
    token = other_actors_clickwrap_token_for(:signup, actor: @user, other_actor: other)
    submission = Clickwrap::Submission.new(presentation_token: token,
                                           answers: { "terms" => "1", "privacy_notice" => "1" })

    error = assert_raises(Clickwrap::PresentationInvalid) do
      Clickwrap.capture!(:signup, actor: @user, submission: submission)
    end

    assert_equal :presentation_actor_mismatch, error.result.error

    assert_raises(ArgumentError) do
      other_actors_clickwrap_token_for(:signup, actor: @user, other_actor: @user)
    end
  end

  test "submitting the same presentation twice returns one event" do
    first, second = submit_clickwrap_twice(:signup, actor: @user,
                                                    answers: { terms: "1", privacy_notice: "1" })

    assert_equal first.event_id, second.event_id
  end

  test "the module-level form of the collision-prone helpers works" do
    receipt = Clickwrap::TestHelpers.submit_clickwrap(
      :signup, actor: @user, answers: { terms: "1", privacy_notice: "1" }
    )

    assert receipt.event_id.present?
  end

  test "exemption assertions ask the separate question" do
    Clickwrap.exempt!(:seeded_signup, actor: Clickwrap.system_actor("database_seed"),
                                      subject: @user, because: "Generated demo account")

    assert_clickwrap_exempted_from :seeded_signup,
                                   actor: Clickwrap.system_actor("database_seed"), subject: @user
    refute_clickwrap_current :seeded_signup, actor: @user
  end

  test "assert_clickwrap_receipt_verifies and the current/agreed assertions" do
    receipt = submit_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })

    assert_clickwrap_current :signup, actor: @user
    assert_clickwrap_agreed_to :terms, actor: @user
    assert_clickwrap_acknowledged :privacy_notice, actor: @user
    assert_clickwrap_receipt_verifies receipt

    other = create_user
    refute_clickwrap_current :signup, actor: other
    assert_no_clickwrap_event :marketing_preferences, actor: other
  end

  test "assertion failure messages explain themselves" do
    error = assert_raises(Minitest::Assertion) { assert_clickwrap_agreed_to :terms, actor: @user }
    assert_includes error.message, "Nothing is recorded"

    error = assert_raises(Minitest::Assertion) { assert_clickwrap_current :signup, actor: @user }
    assert_includes error.message, "no_evidence"
  end

  # --- ReceiptVerifier --------------------------------------------------------

  test "the standalone verifier validates receipt internals and reports missing document artifacts" do
    receipt = submit_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })

    # No hand-built stand-in: this is exactly the bytes `to_canonical_json`
    # produces, which is exactly what a host writes to a file.
    result = Clickwrap::ReceiptVerifier.verify(receipt.to_canonical_json)

    refute result.success?, result.to_s
    assert result.failures.empty?, result.to_s
    assert result.skipped.any?, result.to_s
    assert_equal "clickwrap.receipt.v1", result.schema
    assert(result.checks.any? { |check| check.name == "receipt_digest" && check.passed? })
    assert(result.checks.any? { |check| check.name == "canonical_bytes" && check.passed? })
  end

  test "the standalone verifier checks supplied document bytes and reports the ones it was not given" do
    receipt = submit_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
    terms = Clickwrap::Document.find_by(document_key: "terms").current_version

    with_terms = Clickwrap::ReceiptVerifier.verify(
      receipt.to_canonical_json,
      documents: {
        "terms" => { source: terms.content_bytes, rendered: terms.rendered_bytes }
      }
    )
    refute with_terms.success?, with_terms.to_s
    assert(with_terms.checks.count { |check| check.name.include?("terms") && check.passed? } == 2)

    # A document nobody supplied is neither a pass nor a failure. Collapsing the
    # three states into two is how "we did not look" becomes "we looked and it
    # was fine".
    assert with_terms.skipped.any?, with_terms.to_s

    wrong = Clickwrap::ReceiptVerifier.verify(
      receipt.to_canonical_json,
      documents: {
        "terms" => {
          source: terms.content_bytes,
          rendered: "these are not the rendered bytes the receipt bound"
        }
      }
    )
    assert_not wrong.success?
    assert(wrong.failures.any? { |check| check.name.include?("terms") })
  end

  test "the standalone verifier detects an edited receipt" do
    receipt = submit_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
    body = JSON.parse(receipt.to_canonical_json)
    body["actor"]["reference"] = "gid://dummy/User/999999"

    result = Clickwrap::ReceiptVerifier.verify(Clickwrap::CanonicalJson.generate(body))

    assert_not result.success?
    assert(result.failures.any? { |check| check.name == "receipt_digest" })
  end

  test "the standalone verifier refuses an unknown schema rather than guessing" do
    receipt = submit_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
    body = JSON.parse(receipt.to_canonical_json)
    body["schema"] = "clickwrap.receipt.v99"

    result = Clickwrap::ReceiptVerifier.verify(Clickwrap::CanonicalJson.generate(body))

    assert_not result.success?
    assert(result.failures.any? { |check| check.detail.include?("clickwrap.receipt.v1") })
  end

  test "the receipt reports both digests and says which one a file can check" do
    receipt = submit_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
    integrity = receipt.to_h["integrity"]

    # Two different values answering two different questions: one says this file
    # has not been edited, the other says the row it describes has not been.
    assert integrity["receipt_digest"].start_with?("sha256:")
    assert integrity["event_digest"].start_with?("sha256:")
    assert_not_equal integrity["receipt_digest"], integrity["event_digest"]
  end

  test "the standalone verifier re-derives every lifecycle successor event" do
    receipt = submit_clickwrap(
      :marketing_preferences,
      actor: @user,
      answers: { product_updates: "1" }
    )
    withdrawal = Clickwrap.withdraw!(
      :product_updates,
      actor: @user,
      because: "The actor withdrew product updates"
    )

    result = Clickwrap::ReceiptVerifier.verify(
      receipt.to_canonical_json,
      documents: document_artifacts_for(receipt)
    )

    assert result.success?, result.to_s
    assert(
      result.checks.any? do |check|
        check.name == "lifecycle_successor:#{withdrawal.id}" && check.passed?
      end
    )
  end

  test "a recomputed receipt digest cannot hide an edited lifecycle successor" do
    receipt = submit_clickwrap(
      :marketing_preferences,
      actor: @user,
      answers: { product_updates: "1" }
    )
    Clickwrap.withdraw!(
      :product_updates,
      actor: @user,
      because: "The actor withdrew product updates"
    )
    body = JSON.parse(receipt.to_canonical_json)
    body.dig("lifecycle", "successors").first["reason"] = "A reason nobody recorded"
    refresh_receipt_digest!(body)

    result = Clickwrap::ReceiptVerifier.verify(
      Clickwrap::CanonicalJson.generate(body),
      documents: document_artifacts_for(receipt)
    )

    assert_not result.success?
    assert(
      result.failures.any? do |check|
        check.name.start_with?("lifecycle_successor:") &&
          check.detail.include?("summary differs")
      end
    )
  end

  private

  def pending_external_action
    withdrawal = create_withdrawal(user: @user)
    [create_pending_external_action(withdrawal), withdrawal]
  end

  def create_pending_external_action(withdrawal)
    presentation = present_clickwrap(
      :withdrawal_authorization,
      actor: @user,
      subject: withdrawal
    )
    Clickwrap.authorize_external_action!(
      :withdrawal_authorization,
      actor: @user,
      subject: withdrawal,
      provider_name: "stripe",
      submission: submission_for(
        presentation,
        {
          withdrawal_requirements: "1",
          coverage_exclusivity: "1",
          withdrawal: "1"
        }
      )
    )
  end

  def document_artifacts_for(receipt)
    receipt.documents.to_h do |binding|
      version = Clickwrap::DocumentVersion.find(binding.document_version_id)
      [
        "#{binding.document_key}@#{binding.version_label}",
        { source: version.content_bytes, rendered: version.rendered_bytes }
      ]
    end
  end

  def refresh_receipt_digest!(body)
    covered = Marshal.load(Marshal.dump(body))
    covered.fetch("integrity").delete("receipt_digest")
    algorithm = Clickwrap::Digest.algorithm_of(body.dig("integrity", "receipt_digest")) || "sha256"
    body.fetch("integrity")["receipt_digest"] =
      Clickwrap::Digest.digest_canonical(covered, algorithm: algorithm)
  end
end
