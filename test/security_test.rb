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
      end
    end

    # A double-click must never produce two debits.
    assert_equal 1, Clickwrap::Event.for_policy("withdrawal_authorization").count
    assert_equal 1, counter, "the protected action ran #{counter} times"
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
          end
        rescue Clickwrap::Error
          # One of the two is expected to lose the race and be told so plainly.
          nil
        end
      end
    end
    2.times { start_line << true }
    threads.each(&:join)

    assert_equal 1, Clickwrap::Event.for_policy("withdrawal_authorization").count
    assert_equal 1, counter, "the protected action ran #{counter} times"
  end

  test "the same actor cannot hold two live grants for one statement and subject" do
    withdrawal = create_withdrawal(user: @user)

    2.times do
      capture_clickwrap(:withdrawal_authorization, actor: @user, subject: withdrawal,
                                                   answers: { withdrawal_requirements: "1",
                                                              ride_exclusivity: "1", withdrawal: "1" })
    end

    states = Clickwrap::StatementState.for_actor(@user.clickwrap_actor_reference)
                                      .for_statement("withdrawal")
    assert_equal 1, states.count, "the unique index must keep one projection row per identity"
  end

  # --- Evidence integrity -----------------------------------------------------

  test "rewriting an event's row is detected by its digest" do
    receipt = capture_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
    assert receipt.digest_verified?

    # Simulate a privileged actor going around the model's append-only guard.
    Clickwrap::Event.where(id: receipt.event_id)
                    .update_all(actor_reference: @attacker.clickwrap_actor_reference) # rubocop:disable Rails/SkipsModelValidations

    assert_not receipt.event.reload.digest_verified?
    assert_equal :integrity_check_failed, Clickwrap.verify(receipt.event_id).error
  end

  test "an ordinary retention run does not look like tampering" do
    receipt = capture_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })

    # The event's canonical body deliberately excludes the mutable columns —
    # legal-hold state and disposition are facts about today, not about what was
    # recorded. Otherwise a lawful deletion would break every digest it touched.
    receipt.event.set_legal_hold!(true)
    assert receipt.event.reload.digest_verified?

    receipt.event.mark_core_event_disposed!
    assert receipt.event.reload.digest_verified?
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
