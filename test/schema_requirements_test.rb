# frozen_string_literal: true

require "test_helper"

# `clickwrap:install` emits only the tables a default installation can actually
# put a row in. Seven of the seventeen are gated behind a configuration that is
# off by default, and each comes with its own flag.
#
# That trade has exactly one failure mode: turning a capability on and
# forgetting its migration. It must not be discovered by a capture failing in
# production, so it is discovered at boot, reported by the doctor, and refused
# at the entry points nothing else covers — always with the command that fixes
# it.
class SchemaRequirementsTest < ActiveSupport::TestCase
  setup { @user = create_user }

  teardown { Clickwrap::SchemaRequirements.reset! }

  # Pretends the whole installation is present except `absent`, which is the
  # shape of the mistake this exists to catch: a settled schema, one capability
  # switched on, one migration never run.
  def pretend_missing(*absent)
    Clickwrap::SchemaRequirements.stubs(:table_presence).returns(true)
    absent.each { |table| Clickwrap::SchemaRequirements.stubs(:table_presence).with(table).returns(false) }
    Clickwrap::SchemaRequirements.stubs(:pending_migrations?).returns(false)
    Clickwrap::SchemaRequirements.reset!
  end

  test "a configured capability with no tables is reported with the exact command" do
    pretend_missing("clickwrap_request_evidence")
    Clickwrap.config.record_ip_address_by_default = true

    missing = Clickwrap::SchemaRequirements.missing_for_configuration

    assert_equal [:request_evidence], missing.map(&:key)
    assert_match(/records request evidence/, missing.sole.explanation)
    assert_match(%r{bin/rails generate clickwrap:install --with-request-evidence}, missing.sole.explanation)
    assert_match(%r{bin/rails db:migrate}, missing.sole.explanation)
  end

  test "a capability nobody turned on is not a missing table" do
    # A default installation: nothing declared, nothing configured, and none of
    # the optional tables present. That is a correct install, not a broken one.
    Clickwrap.reset!
    pretend_missing("clickwrap_request_evidence", "clickwrap_chain_heads",
                    "clickwrap_integrity_attestations", "clickwrap_presentations")

    assert_empty Clickwrap::SchemaRequirements.missing_for_configuration
  end

  test "an integrity adapter with no tables is reported" do
    Clickwrap.reset!
    pretend_missing("clickwrap_chain_heads")
    Clickwrap.config.chain_event_history_with = :sha256

    assert_equal [:integrity], Clickwrap::SchemaRequirements.missing_for_configuration.map(&:key)
  end

  test "nothing is reported while migrations are still pending" do
    # `rails db:migrate` boots the application before it runs the migration that
    # would satisfy the check. Refusing to boot there would make the fix
    # unrunnable, which is a worse failure than the one being prevented.
    Clickwrap::SchemaRequirements.stubs(:table_presence).returns(true)
    Clickwrap::SchemaRequirements.stubs(:table_presence).with("clickwrap_request_evidence").returns(false)
    Clickwrap::SchemaRequirements.stubs(:pending_migrations?).returns(true)
    Clickwrap::SchemaRequirements.reset!
    Clickwrap.config.record_ip_address_by_default = true

    assert_empty Clickwrap::SchemaRequirements.missing_for_configuration
  end

  test "nothing is reported before Clickwrap itself is installed" do
    # A fresh application, mid-install. Everything is missing, and none of it is
    # a misconfiguration yet.
    Clickwrap::SchemaRequirements.stubs(:table_presence).returns(false)
    Clickwrap::SchemaRequirements.reset!
    Clickwrap.config.record_ip_address_by_default = true

    assert_empty Clickwrap::SchemaRequirements.missing_for_configuration
  end

  # --- The doctor -------------------------------------------------------------

  test "the doctor separates a table that is missing from a table that is simply not installed" do
    pretend_missing("clickwrap_request_evidence", "clickwrap_external_actions")
    Clickwrap.config.record_ip_address_by_default = true

    findings = Clickwrap::Doctor.new.report

    problem = findings.find { |finding| finding.message.include?("--with-request-evidence") }
    assert_predicate problem, :problem?

    # Nothing calls the outbox, so its absence is a fact about this
    # installation, not a fault in it. An operator reading at 03:00 must not go
    # looking for a table that was never meant to be there.
    quiet = findings.find { |finding| finding.message.include?("--with-external-actions") }
    assert_predicate quiet, :ok?
    assert_match(/nothing configured needs them/, quiet.message)
  end

  test "the doctor confirms the tiers the dummy actually installed" do
    findings = Clickwrap::Doctor.new.report

    assert(findings.any? { |finding| finding.ok? && finding.message.include?("--with-integrity") })
    assert_empty(findings.select { |finding| finding.problem? && finding.message.include?("--with-") })
  end

  # --- The entry points nothing else covers -----------------------------------

  test "an external action refuses rather than fail obscurely when its outbox is absent" do
    # Nothing in the configuration announces this capability — it is called, not
    # declared — so the boot check cannot see it coming.
    pretend_missing("clickwrap_external_actions")
    withdrawal = create_withdrawal(user: @user)

    error = assert_raises(Clickwrap::ConfigurationError) do
      Clickwrap.authorize_external_action!(
        :withdrawal_authorization,
        actor: @user,
        subject: withdrawal,
        submission: submission_for(
          present_clickwrap(:withdrawal_authorization, actor: @user, subject: withdrawal),
          default_clickwrap_answers(:withdrawal_authorization, {})
        ),
        provider_name: "payments",
        idempotency_key: SecureRandom.uuid
      ) { |_pending| nil }
    end

    assert_match(/--with-external-actions/, error.message)
    assert_equal 0, Clickwrap::Event.for_policy(:withdrawal_authorization).count
  end

  test "a legal hold refuses rather than fail obscurely when its tables are absent" do
    receipt = submit_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
    pretend_missing("clickwrap_legal_holds")

    error = assert_raises(Clickwrap::ConfigurationError) do
      receipt.place_on_legal_hold!(because: "Litigation hold", placed_by: @user,
                                   review_at: 1.year.from_now)
    end

    assert_match(/--with-retention-ops/, error.message)
  end
end
