# frozen_string_literal: true

require "test_helper"

# The proof integrations, as contract tests.
#
# `docs/strategy/03-readiness-market-and-next-steps.md` defines three proofs that
# decide whether this gem is worth shipping, and `docs/PRD.md` §15 Phase A says to
# represent them as contract tests before any production cutover. They are
# reproduced here against the dummy app rather than against the real downstream
# applications, so the gate can be evaluated without touching either of them.
#
# Each proof states its own failure condition in the test names. If one of these
# starts failing, the answer is not to relax the test.
class ProofsTest < ActiveSupport::TestCase
  # --- Proof A: RailsFast signup — minimality --------------------------------
  #
  # Fails if the integration is not materially smaller and clearer than a
  # bespoke ledger, or if a developer must understand advanced internals.

  test "proof A: the conventional signup path is one policy, one macro, one helper call" do
    user = create_user

    # One policy (config/clickwrap.rb), one macro (has_clickwraps), one helper
    # call — and this, the whole capture. Nothing about manifests, digests,
    # projections, or retention appears in the host's code path.
    receipt = capture_clickwrap(:signup, actor: user, answers: { terms: "1", privacy_notice: "1" })

    assert user.clickwraps.agreed_to?(:terms)
    assert user.clickwraps.acknowledged?(:privacy_notice)
    assert receipt.verify.success?
  end

  test "proof A: terms and the privacy notice keep different meanings" do
    user = create_user
    capture_clickwrap(:signup, actor: user, answers: { terms: "1", privacy_notice: "1" })

    terms = user.clickwraps.statement_states.for_statement("terms").first
    privacy = user.clickwraps.statement_states.for_statement("privacy_notice").first

    # The distinction RailsFast's bespoke implementation could not express: a
    # privacy notice is acknowledged, not agreed to, and neither is consent.
    assert_equal "agreement", terms.kind
    assert_equal "acknowledgment", privacy.kind
    assert_not user.clickwraps.consented_to?(:privacy_notice)
  end

  test "proof A: an account cannot be created without its evidence" do
    # The exact failure RailsFast and CarHey both had: the account is already
    # persisted, the evidence write fails, and the exception is rescued.
    email = "atomic-#{SecureRandom.hex(4)}@example.com"
    prospective_actor = User.new(email: email, name: "New")
    registration_flow_id = SecureRandom.uuid

    Clickwrap::Testing.fail_next_event_write do
      assert_raises(Clickwrap::EventWriteFailed) do
        Clickwrap.register!(:signup, prospective_actor: prospective_actor,
                                     registration_flow_id: registration_flow_id,
                                     submission: registration_submission(
                                       prospective_actor, registration_flow_id
                                     )) do
          prospective_actor.save!
        end
      end
    end

    assert_not User.exists?(email: email), "a failed evidence write must not leave an active account"
  end

  test "proof A: signup records account-registration attribution, not a fictional session" do
    email = "reg-#{SecureRandom.hex(4)}@example.com"
    user = User.new(email: email, name: "New")
    registration_flow_id = SecureRandom.uuid

    receipt = Clickwrap.register!(:signup, prospective_actor: user,
                                           registration_flow_id: registration_flow_id,
                                           submission: registration_submission(
                                             user, registration_flow_id
                                           )) do
      user.save!
    end
    receipt = committed_test_receipt(receipt)

    # At first render there was no persisted actor, and the receipt says exactly
    # that rather than implying the person was already authenticated.
    assert_equal "account_registration", receipt.event.reload.attribution_method
    assert_equal false, receipt.to_h.dig("actor", "attribution", "authenticated")
    assert user.present?
  end

  test "proof A: deleting an account does not delete the evidence" do
    user = create_user
    receipt = capture_clickwrap(:signup, actor: user, answers: { terms: "1", privacy_notice: "1" })

    user.destroy

    # RailsFast's `dependent: :delete_all` is the pattern this replaces.
    assert Clickwrap::Event.exists?(id: receipt.event_id)
  end

  # --- Proof B: driver declaration — lifecycle and composition ---------------
  #
  # Fails if the gem replaces the domain model, weakens server ownership, or
  # needs a private hook.

  test "proof B: the declaration's exact wording is bound into the offer and event" do
    user = create_user
    scheme = create_withdrawal(user: user)

    presentation = present_clickwrap(:driver_declaration, actor: user, subject: scheme)
    offered = presentation.statements.first.assertion

    receipt = committed_test_receipt(
      Clickwrap.capture!(:driver_declaration, actor: user, subject: scheme,
                                              submission: submission_for(
                                                presentation, { non_professional_driver: "1" }
                                              ))
    )

    # The original bug recorded Terms acceptance while the server offer omitted
    # the declaration. The offered and recorded sentences are the same string
    # here, and the test would fail if they drifted.
    assert_equal "I declare that I drive privately and not as a professional driver.", offered
    assert_equal offered, receipt.statements.first.assertion_text
  end

  test "proof B: the policy kind is declaration, not generic acceptance" do
    user = create_user
    scheme = create_withdrawal(user: user)
    receipt = capture_clickwrap(:driver_declaration, actor: user, subject: scheme,
                                                     answers: { non_professional_driver: "1" })

    assert_equal "declaration", receipt.statements.first.kind
    assert_equal "declared", receipt.statements.first.action
  end

  test "proof B: scheme, validity, and fingerprint are server-owned" do
    user = create_user
    scheme = create_withdrawal(user: user)
    receipt = capture_clickwrap(:driver_declaration, actor: user, subject: scheme,
                                                     answers: { non_professional_driver: "1" })

    statement = receipt.statements.first
    assert statement.expires_at.present?, "validity comes from the policy, not from the browser"
    assert statement.subject_fingerprint.present?
    assert_equal scheme.to_gid.to_s, receipt.event.subject_key
  end

  test "proof B: the domain record and the evidence commit atomically" do
    user = create_user
    scheme = create_withdrawal(user: user)

    receipt = capture_clickwrap_and(:driver_declaration, actor: user, subject: scheme,
                                                         answers: { non_professional_driver: "1" }) do |pending|
      scheme.update!(state: "declared", authorized_by_clickwrap_event: pending.event_id)
    end

    assert_equal "declared", scheme.reload.state
    assert_equal receipt.event_id, scheme.authorized_by_clickwrap_event
  end

  test "proof B: expiry and renewal work without rewriting the original" do
    user = create_user
    scheme = create_withdrawal(user: user)
    original = capture_clickwrap(:driver_declaration, actor: user, subject: scheme,
                                                      answers: { non_professional_driver: "1" })

    travel_to 13.months.from_now do
      assert_not user.clickwraps.declared?(:non_professional_driver, subject: scheme)

      renewed = capture_clickwrap(:driver_declaration, actor: user, subject: scheme,
                                                       answers: { non_professional_driver: "1" })

      assert user.clickwraps.declared?(:non_professional_driver, subject: scheme)
      assert_not_equal original.event_id, renewed.event_id
      assert Clickwrap::Event.exists?(id: original.event_id)
      assert original.event.reload.digest_verified?
    end
  end

  # --- Proof C: payout authorization — high assurance ------------------------
  #
  # Fails if the authorization can be reused for another withdrawal, or if the
  # gem path is weaker than a hand-written service check.

  test "proof C: several explicit assertions are recorded separately" do
    user = create_user
    withdrawal = create_withdrawal(user: user)
    receipt = capture_clickwrap(:withdrawal_authorization, actor: user, subject: withdrawal,
                                                           answers: withdrawal_answers)

    kinds = receipt.statements.to_h { |s| [s.statement_key, s.kind] }

    assert_equal "acknowledgment", kinds["withdrawal_requirements"]
    assert_equal "declaration", kinds["ride_exclusivity"]
    assert_equal "authorization", kinds["withdrawal"]
  end

  test "proof C: the covered ride set is fingerprinted into the evidence" do
    user = create_user
    withdrawal = create_withdrawal(user: user, covered_ride_ids: "1,2,3")
    capture_clickwrap(:withdrawal_authorization, actor: user, subject: withdrawal,
                                                 answers: withdrawal_answers)

    assert Clickwrap.verify(:withdrawal_authorization, actor: user, subject: withdrawal).success?

    withdrawal.update!(covered_ride_ids: "1,2,3,4")

    # The exact CarHey invariant: evidence covering one ride set must not
    # authorize a payout covering a different one.
    result = Clickwrap.verify(:withdrawal_authorization, actor: user, subject: withdrawal)
    assert_equal :subject_fingerprint_mismatch, result.error
  end

  test "proof C: the authorization cannot be replayed against another withdrawal" do
    user = create_user
    withdrawal = create_withdrawal(user: user)
    other = create_withdrawal(user: user)

    capture_clickwrap_and(:withdrawal_authorization, actor: user, subject: withdrawal,
                                                     answers: withdrawal_answers) do |pending|
      withdrawal.submit!(authorized_by_clickwrap_event: pending.event_id)
    end

    assert_not Clickwrap.verify(:withdrawal_authorization, actor: user, subject: other).success?
    assert_raises(Clickwrap::VerificationFailed) do
      Clickwrap.require!(:withdrawal_authorization, actor: user, subject: other)
    end
  end

  test "proof C: service-boundary verification is available without a controller" do
    user = create_user
    withdrawal = create_withdrawal(user: user)
    capture_clickwrap(:withdrawal_authorization, actor: user, subject: withdrawal,
                                                 answers: withdrawal_answers)

    # Controller gates improve flow; service verification protects the action.
    # The same verifier is callable from a service or a job with no request.
    result = Clickwrap.require!(:withdrawal_authorization, actor: user, subject: withdrawal)
    assert result.success?
  end

  test "proof C: verification returns a stable symbol rather than only a boolean" do
    user = create_user
    withdrawal = create_withdrawal(user: user)

    result = Clickwrap.verify(:withdrawal_authorization, actor: user, subject: withdrawal)

    assert_not result.success?
    assert_includes Clickwrap::Vocabulary::VERIFICATION_ERRORS, result.error
    assert result.message.present?
    assert_equal "withdrawal_authorization", result.policy_key
  end

  # --- The other inventoried surfaces ----------------------------------------

  test "consent withdrawal is exposed as a first-class action with its own route" do
    user = create_user
    capture_clickwrap(:marketing_preferences, actor: user, answers: { product_updates: "1" })

    state = user.clickwraps.consent(:product_updates)
    withdrawal_path = Clickwrap.policies["marketing_preferences"]
                               .statement("product_updates").withdrawal_path

    assert_equal "/settings/privacy", withdrawal_path
    assert_equal "active", state.state

    Clickwrap.withdraw!(:product_updates, actor: user, because: "Withdrawn in privacy settings")
    assert_equal "withdrawn", state.reload.state
  end

  test "B2B guide delivery and marketing consent are separate statements" do
    user = create_user

    # CarHey bundled guide delivery and marketing into one required box. Here
    # each purpose is its own statement, each starts unselected, and taking one
    # does not take the other.
    capture_clickwrap(:marketing_preferences, actor: user, answers: { product_updates: "1" })

    assert user.clickwraps.consented_to?(:product_updates)
    assert_not user.clickwraps.consented_to?(:partner_offers)
  end

  test "an operator attestation records who asserted which operational fact" do
    operator = create_user(role: "operator")

    receipt = capture_clickwrap(:manual_bank_transfer, actor: operator,
                                                       locale: :en,
                                                       capture_channel: :operator,
                                                       answers: {
                                                         beneficiary_matches_verified_identity: "1",
                                                         bank_accepted_transfer: "1"
                                                       })

    assert_equal "operator", receipt.event.capture_channel
    assert_equal %w[attestation attestation], receipt.statements.map(&:kind)
    assert_equal operator.clickwrap_actor_reference, receipt.event.actor_reference
  end

  test "an imported external receipt is never mistaken for a locally captured click" do
    user = create_user

    receipt = Clickwrap.import_external_receipt!(
      :signup,
      actor: user,
      provider_name: "stripe",
      provider_event_id: "acct_123",
      provider_receipt: { "service_agreement" => "full" },
      verified_with: :stripe_api,
      verified_at: Time.current
    )

    event = receipt.respond_to?(:event) ? receipt.event : receipt
    assert_equal "external_receipt", event.event_type
    assert_equal "imported_provider", event.capture_channel
    assert_nil event.presentation_manifest_digest,
               "an imported provider event has no presentation of ours to point at"
    assert_equal "stripe", event.provider_name
  end

  # --- Public forms that find or create their record ---------------------------

  test "a registration flow refuses an already-persisted actor by default and teaches the option" do
    # Passing a persisted record as a prospective actor is usually a bug (the
    # host meant capture! with `actor:`). The refusal says so, and names the
    # explicit opt-in for the one shape where it is legitimate.
    existing = create_user
    registration_flow_id = SecureRandom.uuid

    error = assert_raises(Clickwrap::PresentationInvalid) do
      Clickwrap.register!(:marketing_preferences, prospective_actor: existing,
                                                  registration_flow_id: registration_flow_id,
                                                  submission: public_form_submission(
                                                    existing, registration_flow_id
                                                  )) do
        existing.save!
      end
    end

    assert_match(/actor_may_already_exist: true/, error.message)
    assert_match(/public_form/, error.message)
  end

  test "a public form that matched an existing record captures with honest public_form attribution" do
    # The lead-capture / newsletter shape: an anonymous visitor submits a
    # public form, and the host finds (or creates) the row by typed email.
    # When the row already existed, the receipt must NOT claim an account was
    # registered — `public_form` says an unauthenticated submission named
    # this actor, and nothing more.
    existing = create_user
    registration_flow_id = SecureRandom.uuid

    receipt = Clickwrap.register!(:marketing_preferences, prospective_actor: existing,
                                                          registration_flow_id: registration_flow_id,
                                                          actor_may_already_exist: true,
                                                          submission: public_form_submission(
                                                            existing, registration_flow_id
                                                          )) do
      existing.save!
    end
    receipt = committed_test_receipt(receipt)

    event = receipt.event.reload
    assert_equal "public_form", event.attribution_method
    assert_equal existing.id.to_s, event.actor_id.to_s,
                 "the evidence must bind to the row the form matched"
    assert existing.clickwraps.consented_to?(:product_updates)
  end

  test "the same public form still records account_registration when it created the record" do
    # One call site, both cases, each attributed honestly: whether this
    # submission created the row is a fact decided at capture time, not a
    # separate code path the host has to write.
    fresh = User.new(email: "lead-#{SecureRandom.hex(4)}@example.com", name: "New")
    registration_flow_id = SecureRandom.uuid

    receipt = Clickwrap.register!(:marketing_preferences, prospective_actor: fresh,
                                                          registration_flow_id: registration_flow_id,
                                                          actor_may_already_exist: true,
                                                          submission: public_form_submission(
                                                            fresh, registration_flow_id
                                                          )) do
      fresh.save!
    end
    receipt = committed_test_receipt(receipt)

    assert_equal "account_registration", receipt.event.reload.attribution_method
  end

  private

  def withdrawal_answers
    { withdrawal_requirements: "1", ride_exclusivity: "1", withdrawal: "1" }
  end

  def registration_submission(prospective_actor, registration_flow_id)
    presentation = Clickwrap.present(
      :signup,
      actor: nil,
      prospective_actor: prospective_actor,
      registration_flow_id: registration_flow_id,
      submit_button_text: "Create account"
    )
    submission_for(presentation, { terms: "1", privacy_notice: "1" })
  end

  def public_form_submission(prospective_actor, registration_flow_id)
    presentation = Clickwrap.present(
      :marketing_preferences,
      actor: nil,
      prospective_actor: prospective_actor,
      registration_flow_id: registration_flow_id,
      submit_button_text: "Subscribe"
    )
    submission_for(presentation, { product_updates: "1" })
  end
end
