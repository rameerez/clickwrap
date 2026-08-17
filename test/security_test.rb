# frozen_string_literal: true

require "test_helper"

# The threat model, made executable. Everything here is something Clickwrap
# treats as hostile until verified, and every test names the attack rather than
# the mechanism, so a reader can tell what would go wrong if it regressed.
class SecurityTest < ActiveSupport::TestCase
  setup do
    @user = create_user
    @attacker = create_user
  end

  # --- The client cannot choose a server-owned decision -----------------------

  test "a crafted submission cannot choose a different policy" do
    presentation = present_clickwrap(:signup, actor: @user)

    error = assert_raises(Clickwrap::PresentationInvalid) do
      Clickwrap.capture!(:current_terms, actor: @user,
                                         submission: submission_for(presentation, { terms: "1" }))
    end

    assert_equal :presentation_policy_mismatch, error.result.error
  end

  test "a crafted submission cannot choose a document version or a validity date" do
    %w[document_version version valid_from valid_until expires_at retain_until].each do |field|
      assert_raises(Clickwrap::SubmissionInvalid) do
        Clickwrap::Submission.new(presentation_token: "x", answers: { field => "anything" })
      end
    end
  end

  test "a crafted submission cannot supply its own IP address, user agent, or geolocation" do
    %w[ip_address remote_ip browser_user_agent user_agent ip_geolocation geolocation
       latitude longitude server_observed_ip_address resolver].each do |field|
      error = assert_raises(Clickwrap::SubmissionInvalid) do
        Clickwrap::Submission.new(presentation_token: "x", answers: { field => "1.2.3.4" })
      end

      assert_match(/server-owned decision/, error.message)
    end
  end

  test "unknown envelope fields are refused instead of silently filtered" do
    token = present_clickwrap(:signup, actor: @user).token

    [
      {
        clickwrap_submission: {
          presentation_token: token,
          answers: { terms: "1", privacy_notice: "1" },
          authority_role: "owner"
        }
      },
      ActionController::Parameters.new(
        clickwrap_submission: {
          presentation_token: token,
          answers: { terms: "1", privacy_notice: "1" },
          represented_party_id: "attacker-chosen"
        }
      )
    ].each do |params|
      error = assert_raises(Clickwrap::SubmissionInvalid) do
        Clickwrap::Submission.from_params(params)
      end

      assert_match(/may contain only presentation_token and answers/, error.message)
    end
  end

  test "duplicate string and symbol envelope keys are refused as ambiguous" do
    params = {
      clickwrap_submission: {
        "presentation_token" => "first",
        presentation_token: "second",
        answers: {}
      }
    }

    error = assert_raises(Clickwrap::SubmissionInvalid) do
      Clickwrap::Submission.from_params(params)
    end

    assert_match(/duplicate keys presentation_token/, error.message)
  end

  test "public capture methods do not expose lifecycle event or action overrides" do
    presentation = present_clickwrap(:signup, actor: @user)
    submission = submission_for(presentation, { terms: "1", privacy_notice: "1" })

    %i[event_type root_event_id predecessor_event_id statement_action_overrides].each do |keyword|
      assert_raises(ArgumentError) do
        Clickwrap.capture!(
          :signup,
          **{ actor: @user, submission: submission, keyword => "forged" }
        )
      end
    end

    assert_no_clickwrap_event :signup, actor: @user
  end

  test "the presenter never renders a hidden field carrying a server-owned decision" do
    presentation = present_clickwrap(:regulated_authorization, actor: @user,
                                                               subject: create_withdrawal(user: @user))
    manifest = presentation.manifest.to_h

    # The manifest is signed, so its contents are safe to send. What must never
    # appear is a field the browser could edit and the server would then trust.
    refute manifest.key?("ip_address")
    refute manifest.key?("browser_user_agent")
    refute manifest.key?("ip_geolocation")

    control_names = presentation.statements.map(&:control_name)
    control_names.each do |name|
      assert_match(/\Aclickwrap_submission\[answers\]\[/, name)
    end
  end

  # --- Token attacks ----------------------------------------------------------

  test "a token signed with a different secret is rejected" do
    presentation = present_clickwrap(:signup, actor: @user)
    foreign = ActiveSupport::MessageVerifier.new("a-completely-different-secret", digest: "SHA256",
                                                                                  serializer: JSON)
    forged = foreign.generate(presentation.manifest.to_h,
                              purpose: Clickwrap::PresentationManifest::SIGNING_PURPOSE)

    assert_raises(Clickwrap::PresentationInvalid) do
      Clickwrap.capture!(:signup, actor: @user,
                                  submission: Clickwrap::Submission.new(presentation_token: forged,
                                                                        answers: { "terms" => "1" }))
    end
  end

  test "a token generated for a different purpose is rejected" do
    verifier = Clickwrap::PresentationManifest.verifier
    presentation = present_clickwrap(:signup, actor: @user)
    wrong_purpose = verifier.generate(presentation.manifest.to_h, purpose: "something/else")

    assert_raises(Clickwrap::PresentationInvalid) do
      Clickwrap::PresentationManifest.from_token(wrong_purpose)
    end
  end

  test "a missing token is refused rather than treated as an empty submission" do
    assert_raises(Clickwrap::PresentationInvalid) do
      Clickwrap.capture!(:signup, actor: @user,
                                  submission: Clickwrap::Submission.new(presentation_token: nil))
    end
  end

  test "an attacker cannot swap the actor inside a token" do
    presentation = present_clickwrap(:signup, actor: @user)
    tampered_attributes = presentation.manifest.to_h.merge(
      "actor" => { "reference" => @attacker.clickwrap_actor_reference, "type" => "User" }
    )
    # Re-signing requires the secret. Without it, the payload cannot be changed.
    forged = ActiveSupport::MessageVerifier.new("guessed-secret", digest: "SHA256", serializer: JSON)
                                           .generate(tampered_attributes,
                                                     purpose: Clickwrap::PresentationManifest::SIGNING_PURPOSE)

    assert_raises(Clickwrap::PresentationInvalid) do
      Clickwrap.capture!(:signup, actor: @attacker,
                                  submission: Clickwrap::Submission.new(presentation_token: forged,
                                                                        answers: { "terms" => "1" }))
    end
  end

  test "a non-string host actor reference is normalized before it enters the signed presentation" do
    Clickwrap.config.identify_actor_with = ->(_actor) { :host_owned_reference }
    presentation = present_clickwrap(:signup, actor: @user)

    receipt = committed_test_receipt(Clickwrap.capture!(
                                       :signup,
                                       actor: @user,
                                       submission: submission_for(presentation, { terms: "1", privacy_notice: "1" })
                                     ))

    assert_equal "host_owned_reference", presentation.manifest.actor_reference
    assert_equal "host_owned_reference", receipt.actor_reference
  end

  test "a literal reference can be the actor on both presentation and capture" do
    actor_reference = "external/account-123"
    presentation = present_clickwrap(:signup, actor: actor_reference)

    receipt = committed_test_receipt(Clickwrap.capture!(
                                       :signup,
                                       actor: actor_reference,
                                       submission: submission_for(presentation, { terms: "1", privacy_notice: "1" })
                                     ))

    assert_equal actor_reference, receipt.actor_reference
  end

  test "a token issued to one tenant cannot be captured for another" do
    organization = create_organization
    other_organization = create_organization
    presentation = present_clickwrap(:signup, actor: @user, tenant: organization)

    error = assert_raises(Clickwrap::PresentationInvalid) do
      Clickwrap.capture!(:signup, actor: @user, tenant: other_organization,
                                  submission: submission_for(presentation,
                                                             { terms: "1", privacy_notice: "1" }))
    end

    assert_equal :presentation_tenant_mismatch, error.result.error
  end

  # --- Concurrency ------------------------------------------------------------

  test "a repeated submit of the same presentation produces one event and one action" do
    withdrawal = create_withdrawal(user: @user)
    presentation = present_clickwrap(:withdrawal_authorization, actor: @user, subject: withdrawal)
    answers = { withdrawal_requirements: "1", ride_exclusivity: "1", withdrawal: "1" }
    counter = 0

    2.times do
      Clickwrap.capture_and!(:withdrawal_authorization, actor: @user, subject: withdrawal,
                                                        submission: submission_for(presentation, answers)) do
        counter += 1
        withdrawal
      end
    end

    # A double-click must never produce two debits.
    assert_equal 1, Clickwrap::Event.captures.for_policy("withdrawal_authorization").count
    assert_equal 1, Clickwrap::Event.for_policy("withdrawal_authorization")
                                    .where(event_type: "consumption").count
    assert_equal 1, counter, "the protected action ran #{counter} times"
  end

  test "two presentations issued before a one-time action cannot both perform it" do
    withdrawal = create_withdrawal(user: @user)
    first = present_clickwrap(:withdrawal_authorization, actor: @user, subject: withdrawal)
    second = present_clickwrap(:withdrawal_authorization, actor: @user, subject: withdrawal)
    answers = { withdrawal_requirements: "1", ride_exclusivity: "1", withdrawal: "1" }
    counter = 0

    Clickwrap.capture_and!(:withdrawal_authorization, actor: @user, subject: withdrawal,
                                                      submission: submission_for(first, answers)) do
      counter += 1
      withdrawal
    end

    error = assert_raises(Clickwrap::OneTimeAuthorizationConflict) do
      Clickwrap.capture_and!(:withdrawal_authorization, actor: @user, subject: withdrawal,
                                                        submission: submission_for(second, answers)) do
        counter += 1
        withdrawal
      end
    end

    assert_match(/render a new presentation/i, error.message)
    assert_equal 1, counter
    assert_equal 1, Clickwrap::Event.captures.for_policy("withdrawal_authorization").count
    expected_lock_digests = [
      Clickwrap::StatementIdentityLock.actor_state_scope_for(@user.clickwrap_actor_reference),
      *Clickwrap::StatementState.for_actor(@user.clickwrap_actor_reference)
                                .for_policy("withdrawal_authorization")
                                .pluck(:identity_digest)
    ].uniq
    recorded_lock_digests = Clickwrap::StatementIdentityLock.where(identity_digest: expected_lock_digests)
                                                            .pluck(:identity_digest)

    assert_equal 1 + Clickwrap.policy!(:withdrawal_authorization).statements.size,
                 expected_lock_digests.size
    assert_empty expected_lock_digests - recorded_lock_digests,
                 "the actor-wide lock and every affected statement projection need coordination rows"
  end

  test "a new presentation after terminal state can create a deliberate new authorization" do
    withdrawal = create_withdrawal(user: @user)
    answers = { withdrawal_requirements: "1", ride_exclusivity: "1", withdrawal: "1" }

    first = present_clickwrap(:withdrawal_authorization, actor: @user, subject: withdrawal)
    Clickwrap.capture_and!(:withdrawal_authorization, actor: @user, subject: withdrawal,
                                                      submission: submission_for(first, answers)) { withdrawal }

    travel 1.second do
      second = present_clickwrap(:withdrawal_authorization, actor: @user, subject: withdrawal)
      Clickwrap.capture_and!(:withdrawal_authorization, actor: @user, subject: withdrawal,
                                                        submission: submission_for(second, answers)) { withdrawal }
    end

    assert_equal 2, Clickwrap::Event.captures.for_policy("withdrawal_authorization").count
    assert_equal 2, Clickwrap::Event.where(policy_key: "withdrawal_authorization",
                                           event_type: "consumption").count
  end

  test "two genuinely concurrent submits still produce one event and one action" do
    # The test above proves the idempotency lookup finds an existing event. This
    # one proves the case that actually matters under load: two requests in
    # flight at once, where the lookup finds nothing and BOTH proceed to insert.
    # What settles that race is the unique index on
    # (policy_key, idempotency_key), and only a real concurrent write reaches it.
    #
    # SQLite allows a single writer, so threads here would queue on the file
    # rather than race in the database, and the result would say more about
    # SQLite's locking than about Clickwrap. PostgreSQL and MySQL run this lane
    # in CI; the sequential test above runs everywhere.
    adapter = ActiveRecord::Base.connection.adapter_name.downcase
    skip "concurrent writers need PostgreSQL or MySQL (this lane is #{adapter})" if adapter.include?("sqlite")

    withdrawal = create_withdrawal(user: @user)
    presentation = present_clickwrap(:withdrawal_authorization, actor: @user, subject: withdrawal)
    answers = { withdrawal_requirements: "1", ride_exclusivity: "1", withdrawal: "1" }
    counter = 0
    mutex = Mutex.new
    start_line = Queue.new

    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          start_line.pop
          Clickwrap.capture_and!(:withdrawal_authorization, actor: @user, subject: withdrawal,
                                                            submission: submission_for(presentation, answers)) do
            mutex.synchronize { counter += 1 }
            withdrawal
          end
        rescue Clickwrap::Error
          # One of the two is expected to lose the race and be told so plainly.
          nil
        end
      end
    end
    2.times { start_line << true }
    threads.each(&:join)

    assert_equal 1, Clickwrap::Event.captures.for_policy("withdrawal_authorization").count
    assert_equal 1, counter, "the protected action ran #{counter} times"
  end

  test "the same actor cannot hold two live grants for one statement and subject" do
    withdrawal = create_withdrawal(user: @user)

    capture_clickwrap(:withdrawal_authorization, actor: @user, subject: withdrawal,
                                                 answers: { withdrawal_requirements: "1",
                                                            ride_exclusivity: "1", withdrawal: "1" })

    assert_raises(Clickwrap::OneTimeAuthorizationConflict) do
      capture_clickwrap(:withdrawal_authorization, actor: @user, subject: withdrawal,
                                                   answers: { withdrawal_requirements: "1",
                                                              ride_exclusivity: "1", withdrawal: "1" })
    end

    states = Clickwrap::StatementState.for_actor(@user.clickwrap_actor_reference)
                                      .for_statement("withdrawal")
    assert_equal 1, states.count, "the unique index must keep one projection row per identity"
    assert_equal 1, Clickwrap::Event.captures.for_policy("withdrawal_authorization").count
  end

  # --- Evidence integrity -----------------------------------------------------

  test "rewriting an event's row is detected by its digest" do
    receipt = capture_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
    assert receipt.digest_verified?

    # Simulate a privileged actor going around the model's append-only guard.
    Clickwrap::Event.where(id: receipt.event_id)
                    .update_all(actor_reference: @attacker.clickwrap_actor_reference)

    assert_not receipt.event.reload.digest_verified?
    assert_equal :integrity_check_failed, Clickwrap.verify(receipt.event_id).error
  end

  test "an ordinary retention run leaves a verifiable documented tombstone" do
    receipt = capture_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })

    # A hold is current control state rather than historical payload, so it does
    # not rewrite the event digest.
    receipt.event.set_legal_hold!(true)
    assert receipt.event.reload.digest_verified?

    receipt.event.set_legal_hold!(false)
    Clickwrap::Retention::Disposition.dispose_core_event!(
      receipt.event,
      because: "The reviewed retention period ended"
    )

    event = receipt.event.reload
    assert_not event.digest_verified?, "the removed payload is no longer available to re-derive"
    assert event.documented_core_disposition?
    assert_equal :core_event_disposed, Clickwrap.verify(event.id).error
  end

  test "a raw disposition marker cannot hide intact or altered evidence from verification" do
    receipt = capture_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })

    # The marker is deliberately outside the historical digest because a real
    # retention run writes it later. That makes the linked disposition event the
    # required proof. A privileged update that writes only the marker must fail
    # closed, even though the original payload still hashes correctly.
    Clickwrap::Event.where(id: receipt.event_id).update_all(core_event_disposed_at: Clickwrap.now)
    event = receipt.event.reload

    assert event.digest_verified?
    assert_not event.documented_core_disposition?
    assert_equal :unaccounted_mismatch, event.digest_integrity_status

    event_result = Clickwrap.verify(event.id)
    policy_result = Clickwrap.verify(:signup, actor: @user)

    assert_equal :integrity_check_failed, event_result.error
    assert_equal "not_documented", event_result.details["disposition"]
    assert_equal :integrity_check_failed, policy_result.error
    assert_equal "not_documented", policy_result.details["disposition"]
  end

  test "a digest-valid non-disposition event cannot be used as a disposition proof" do
    receipt = capture_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
    disposed_at = Clickwrap.now
    fake = Clickwrap::Lifecycle.append_lifecycle_event!(
      event: receipt.event,
      event_type: "legal_hold_placed",
      reason: "A legitimate hold event carrying hostile host metadata",
      extra: {
        protected_outcome: {
          "core_event_disposition" => {
            "event_id" => receipt.event_id,
            "original_event_digest" => receipt.event.event_digest,
            "disposed_at" => Clickwrap::Receipt.format_time(disposed_at)
          }
        }
      }
    )
    assert fake.digest_verified?

    Clickwrap::Event.where(id: receipt.event_id).update_all(
      core_event_disposed_at: disposed_at,
      core_event_disposition_event_id: fake.id
    )
    event = receipt.event.reload

    assert_not event.documented_core_disposition?
    assert_equal :unaccounted_mismatch, event.digest_integrity_status
    assert_equal :integrity_check_failed, Clickwrap.verify(event.id).error
  end

  test "an actor deletion never cascades evidence away" do
    receipt = capture_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
    reference = @user.clickwrap_actor_reference

    @user.destroy

    event = Clickwrap::Event.find_by(id: receipt.event_id)
    assert event.present?, "deleting an account must not erase the record of what they agreed to"
    assert_nil event.actor_id
    assert_equal reference, event.actor_reference
    assert event.digest_verified?
  end

  # --- Actor identity ---------------------------------------------------------

  test "an IP address is refused as an anonymous actor identifier" do
    ["203.0.113.10", "2001:db8::1"].each do |address|
      error = assert_raises(ArgumentError) { Clickwrap.anonymous_actor(address) }
      assert_match(/not an actor/, error.message)
    end
  end

  test "an anonymous actor and a system actor are distinguishable in evidence" do
    assert_equal "anonymous/checkout_abc", Clickwrap.anonymous_actor("checkout_abc").clickwrap_actor_reference
    assert_equal "system/database_seed", Clickwrap.system_actor("database_seed").clickwrap_actor_reference
  end

  # --- Remediation authorization ----------------------------------------------

  test "a gate refuses to remediate a subject the host did not authorize this actor for" do
    # The gate resolves the subject SERVER-SIDE and then asks the host whether
    # this actor may remediate for it. Without that question, a gate declared
    # with `subject_with:` would happily mint a signed remediation token for
    # somebody else's record. The integration tests see this as a 404 — the
    # denial must not disclose that the record exists — which is exactly why
    # the raise itself needs pinning: a 404 can come from several places, and
    # only one of them is this check.
    someone_elses = create_withdrawal(user: @attacker)
    controller = WithdrawalReviewsController.new

    error = assert_raises(Clickwrap::RemediationNotAuthorized) do
      controller.send(:authorize_clickwrap_remediation_context!, :driver_declaration,
                      actor: @user, subject: someone_elses, represented_party: nil)
    end

    assert_match(/did not authorize this actor/, error.message)
    assert_kind_of Clickwrap::RemediationInvalid, error
  end

  test "a gate refuses to remediate for a represented party the host did not authorize" do
    controller = WithdrawalReviewsController.new
    Clickwrap.config.authorize_clickwrap_remediation_represented_party_with =
      ->(actor:, represented_party:, policy:, controller:) { false }

    assert_raises(Clickwrap::RemediationNotAuthorized) do
      controller.send(:authorize_clickwrap_remediation_context!, :driver_declaration,
                      actor: @user, subject: nil, represented_party: create_organization)
    end
  end

  # --- Leakage ----------------------------------------------------------------

  test "no prohibited claim appears anywhere in the shipped library or its output" do
    receipt = capture_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
    surfaces = [receipt.to_canonical_json, receipt.to_html, Clickwrap::Doctor.new.report.to_s]

    Clickwrap::Vocabulary::PROHIBITED_CLAIM_PHRASES.each do |phrase|
      surfaces.each do |surface|
        assert_not surface.downcase.include?(phrase),
                   "#{phrase.inspect} must never appear in user-facing output"
      end
    end
  end
end
