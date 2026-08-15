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

    # The projection answers current-state questions after a migration.
    assert_clickwrap_agreed_to :terms, actor: @user
    assert_clickwrap_acknowledged :privacy_notice, actor: @user
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

  # --- Import::FinePrint ------------------------------------------------------

  test "the FinePrint importer says plainly that the tables are absent" do
    report = Clickwrap::Import::FinePrint.plan(
      policy_key: :signup, find_actor_with: ->(_type, _id) { @user }
    )

    assert_not report.possible?
    assert_equal :tables_absent, report.status
    assert_includes report.message, "fine_print_contracts"
    assert_equal 0, Clickwrap::Event.count
  end

  test "the FinePrint importer reads real tables when they are there" do
    connection = ActiveRecord::Base.connection
    connection.create_table(:fine_print_contracts, force: true) do |t|
      t.string :name
      t.string :version
      t.string :title
      t.text :content
      t.timestamps
    end
    connection.create_table(:fine_print_signatures, force: true) do |t|
      t.integer :contract_id
      t.string :user_type
      t.integer :user_id
      t.timestamps
    end

    contract_id = connection.insert(
      "INSERT INTO fine_print_contracts (name, version, title, created_at, updated_at) " \
      "VALUES ('terms', '3', 'Terms of Use', '2019-01-01', '2019-01-01')"
    )
    connection.insert(
      "INSERT INTO fine_print_signatures (contract_id, user_type, user_id, created_at, updated_at) " \
      "VALUES (#{contract_id}, 'User', #{@user.id}, '2019-02-03 10:00:00', '2019-02-03 10:00:00')"
    )

    plan = Clickwrap::Import::FinePrint.plan(
      policy_key: :signup, find_actor_with: ->(_type, id) { User.find(id) }
    )
    assert plan.possible?
    assert_equal 1, plan.signatures
    assert_equal 0, Clickwrap::Event.count
    assert_includes plan.message, "unknown"

    report = Clickwrap::Import::FinePrint.import!(
      policy_key: :signup, find_actor_with: ->(_type, id) { User.find(id) }
    )

    assert_equal 1, report.imported.length
    event = report.imported.first.event
    assert_equal "imported_legacy", event.event_type
    assert_nil event.presentation_manifest_digest
    assert_equal 2019, event.occurred_at.year
    assert_includes event.provider_verification["unknown"], "ip_address"
    assert_equal "fine_print", event.provider_verification["source"]

    # Re-running is a no-op.
    rerun = Clickwrap::Import::FinePrint.import!(
      policy_key: :signup, find_actor_with: ->(_type, id) { User.find(id) }
    )
    assert_equal 1, rerun.already_imported.length
    assert_equal 1, Clickwrap::Event.for_policy("signup").count
  ensure
    connection.drop_table(:fine_print_signatures, if_exists: true)
    connection.drop_table(:fine_print_contracts, if_exists: true)
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
                                                 ride_exclusivity: "1", withdrawal: "1" })
    )

    assert_kind_of Clickwrap::ExternalAction, action
    assert action.pending?
    assert_equal "stripe", action.provider_name
    assert_includes action.idempotency_key, action.event_id
    assert_equal "capture", action.event.event_type

    action.record_provider_success_and_consume!({ "id" => "pi_1" })
    assert_equal "succeeded", action.reload.state

    # The one-time authorization was consumed, so it cannot authorize again.
    assert_not @user.clickwraps.authorized?(:withdrawal, subject: withdrawal)
  end

  test "a repeated authorization request reuses the same outbox row and key" do
    withdrawal = create_withdrawal(user: @user)
    presentation = present_clickwrap(:withdrawal_authorization, actor: @user, subject: withdrawal)
    answers = { withdrawal_requirements: "1", ride_exclusivity: "1", withdrawal: "1" }

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

  # --- Testing ---------------------------------------------------------------

  test "fail_next_event_write raises inside the capture transaction and rolls the action back" do
    withdrawal = create_withdrawal(user: @user)
    ran = false

    Clickwrap::Testing.fail_next_event_write do
      assert_raises(Clickwrap::EventWriteFailed) do
        capture_clickwrap_and(:withdrawal_authorization, actor: @user, subject: withdrawal,
                                                         answers: { withdrawal_requirements: "1",
                                                                    ride_exclusivity: "1",
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
    receipt = capture_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
    assert receipt.event_id.present?
  end

  test "fail_next_domain_write takes the evidence down with the domain write" do
    withdrawal = create_withdrawal(user: @user)

    Clickwrap::Testing.fail_next_domain_write do
      assert_raises(Clickwrap::Testing::DomainWriteFailed) do
        capture_clickwrap_and(:withdrawal_authorization, actor: @user, subject: withdrawal,
                                                         answers: { withdrawal_requirements: "1",
                                                                    ride_exclusivity: "1",
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
      receipt = capture_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
      assert_equal moment.to_i, receipt.event.recorded_at_by_server.to_i
    end

    assert_operator Clickwrap.now, :>=, before
    assert_not_equal moment, Clickwrap.now
  end

  test "reset! is a no-op when nothing was installed" do
    Clickwrap::Testing.reset!
    Clickwrap::Testing.reset!
    receipt = capture_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
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
    receipt = Clickwrap::TestHelpers.capture_clickwrap(
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
    receipt = capture_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })

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

  test "the standalone verifier reads a real exported receipt" do
    receipt = capture_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })

    # No hand-built stand-in: this is exactly the bytes `to_canonical_json`
    # produces, which is exactly what a host writes to a file.
    result = Clickwrap::ReceiptVerifier.verify(receipt.to_canonical_json)

    assert result.success?, result.to_s
    assert_equal "clickwrap.receipt.v1", result.schema
    assert(result.checks.any? { |check| check.name == "receipt_digest" && check.passed? })
    assert(result.checks.any? { |check| check.name == "canonical_bytes" && check.passed? })
  end

  test "the standalone verifier checks supplied document bytes and reports the ones it was not given" do
    receipt = capture_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
    terms = Clickwrap::Document.find_by(key: "terms").current_version

    with_terms = Clickwrap::ReceiptVerifier.verify(
      receipt.to_canonical_json, documents: { "terms" => terms.content_bytes }
    )
    assert with_terms.success?, with_terms.to_s
    assert(with_terms.checks.any? { |check| check.name.include?("terms") && check.passed? })

    # A document nobody supplied is neither a pass nor a failure. Collapsing the
    # three states into two is how "we did not look" becomes "we looked and it
    # was fine".
    assert with_terms.skipped.any?, with_terms.to_s

    wrong = Clickwrap::ReceiptVerifier.verify(
      receipt.to_canonical_json, documents: { "terms" => "these are not the bytes that were shown" }
    )
    assert_not wrong.success?
    assert(wrong.failures.any? { |check| check.name.include?("terms") })
  end

  test "the standalone verifier detects an edited receipt" do
    receipt = capture_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
    body = JSON.parse(receipt.to_canonical_json)
    body["actor"]["reference"] = "gid://dummy/User/999999"

    result = Clickwrap::ReceiptVerifier.verify(Clickwrap::CanonicalJson.generate(body))

    assert_not result.success?
    assert(result.failures.any? { |check| check.name == "receipt_digest" })
  end

  test "the standalone verifier refuses an unknown schema rather than guessing" do
    receipt = capture_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
    body = JSON.parse(receipt.to_canonical_json)
    body["schema"] = "clickwrap.receipt.v99"

    result = Clickwrap::ReceiptVerifier.verify(Clickwrap::CanonicalJson.generate(body))

    assert_not result.success?
    assert(result.failures.any? { |check| check.detail.include?("clickwrap.receipt.v1") })
  end

  test "the receipt reports both digests and says which one a file can check" do
    receipt = capture_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
    integrity = receipt.to_h["integrity"]

    # Two different values answering two different questions: one says this file
    # has not been edited, the other says the row it describes has not been.
    assert integrity["receipt_digest"].start_with?("sha256:")
    assert integrity["event_digest"].start_with?("sha256:")
    assert_not_equal integrity["receipt_digest"], integrity["event_digest"]
  end
end
