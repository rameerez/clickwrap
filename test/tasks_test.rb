# frozen_string_literal: true

require "test_helper"

# The operator surface, exercised the way an operator meets it: through the rake
# tasks, reading what they print.
#
# Two rules hold across all of them. Nothing prints a verdict, and destructive
# work takes two steps — `retention:plan` writes a plan and deletes nothing,
# `retention:apply` refuses to run without that plan's id, and there is no
# `--all` and no `--yes`.
class TasksTest < ActiveSupport::TestCase
  class TimestampAdapter
    attr_reader :digests

    def initialize = @digests = []

    def timestamp(digest)
      digests << digest
      { issued: true, token: "task-token", digest: digest, provider_name: "task_test" }
    end

    def verify(token, _digest) = { checked: true, verified: token == "task-token" }
    def capabilities = { name: "task_test", independently_verifiable: true }
  end

  # Rake's task table is global and `load_tasks` appends to it, so loading the
  # tasks a second time would run every task body twice per invocation.
  def self.load_clickwrap_tasks!
    return if @clickwrap_tasks_loaded

    Rails.application.load_tasks
    @clickwrap_tasks_loaded = true
  end

  setup do
    self.class.load_clickwrap_tasks!

    @user = create_user
    @receipt = submit_clickwrap(:signup, actor: @user)
  end

  # --- Publishing rides db:prepare -------------------------------------------

  test "db:prepare is enhanced to publish declared documents afterwards" do
    assert Rake::Task.task_defined?("clickwrap:publish_after_database_preparation"),
           "the follow-through task must exist for db:prepare to invoke"
    assert Rake::Task["db:prepare"].actions.any? { |action|
             action.source_location&.first&.end_with?("lib/tasks/clickwrap.rake")
           }, "db:prepare must carry the clickwrap publishing follow-through"
  end

  test "the follow-through publishes, and the host opt-out silences it entirely" do
    Rake::Task["clickwrap:publish"].reenable
    output = run_task("clickwrap:publish_after_database_preparation")
    assert_match(/Publishing documents/, output)

    Clickwrap.config.publish_documents_after_database_preparation = false
    Rake::Task["clickwrap:publish"].reenable
    output = run_task("clickwrap:publish_after_database_preparation")
    assert_empty output
  end

  # --- Reporting --------------------------------------------------------------

  test "clickwrap:doctor prints one line per finding and reaches no verdict" do
    output = run_task("clickwrap:doctor")
    lines = output.lines.map(&:chomp).reject(&:empty?)

    assert_match(/policies compiled/, output)
    assert_match(/all referenced documents are published and digest-verified/, output)
    assert lines.all? { |line| line.start_with?("✓ ", "! ", "✗ ") },
           "every doctor line carries its status symbol: #{lines.inspect}"
    refute_prohibited_claims(output)
  end

  test "clickwrap:doctor can print the same findings as JSON for a monitor to read" do
    findings = JSON.parse(run_task("clickwrap:doctor", "FORMAT" => "json"))

    # A monitor branches on the status, never on the English.
    assert(findings.any? { |finding| finding["message"].include?("policies compiled") })
    assert(findings.all? { |finding| %w[ok warning problem].include?(finding["status"]) })
  end

  test "clickwrap:publish:plan says what publishing would do and writes nothing" do
    output = nil

    assert_no_difference -> { Clickwrap::DocumentVersion.count } do
      output = run_task("clickwrap:publish:plan")
    end

    assert_match(/Publishing plan \(nothing was written\)/, output)
    assert_match(/terms/, output)
    refute_prohibited_claims(output)
  end

  test "clickwrap:privacy:inventory describes what is recorded and says that is all it does" do
    output = run_task("clickwrap:privacy:inventory")

    assert_match(/Request-evidence inventory/, output)
    assert_match(/records anything by default: false/, output)
    assert_match(/regulated_authorization \(retention class regulated_evidence\)/, output)
    assert_match(/Investigate account compromise and disputes about this action/, output)
    assert_match(/legal basis reference: DUMMY-LIA-SECURITY-2026-01/, output)
    assert_match(/review on: 2027-08-15/, output)

    # The closing sentence is the point of the whole task.
    assert_match(/This describes a configuration\./, output)
    assert_match(/not the same as/, output)
    refute_prohibited_claims(output)
  end

  test "clickwrap:verify walks the chain and recomputes digests, and states what that shows" do
    output = run_task("clickwrap:verify")

    assert_match(/Chain verification/, output)
    assert_match(/chaining enabled:\s+false/, output)
    assert_match(/Event digests/, output)
    assert_match(/events checked:\s+1/, output)
    assert_match(/documented core dispositions:\s+0/, output)
    assert_match(/unexplained mismatches:\s+0/, output)

    # A verifying digest detects modification of the bytes it covers. The task
    # says so in the same breath as printing the green numbers.
    assert_match(/does not establish who produced them or when/, output)
    refute_prohibited_claims(output)
  end

  test "clickwrap:verify reports one event by id, including whether its digest still verifies" do
    output = run_task("clickwrap:verify", "EVENT_ID" => @receipt.event_id)

    assert_match(/Event #{@receipt.event_id}/, output)
    assert_match(/policy:\s+signup \(capture\)/, output)
    assert_match(/digest verifies:\s+true/, output)
    assert_match(/verification:\s+satisfied/, output)
  end

  test "clickwrap:verify distinguishes a documented disposition from a verifying digest" do
    Clickwrap::Retention::Disposition.dispose_core_event!(
      @receipt.event,
      because: "The reviewed retention period ended"
    )

    output = run_task("clickwrap:verify", "EVENT_ID" => @receipt.event_id)

    assert_match(/digest verifies:\s+false/, output)
    assert_match(/core disposition documented:\s+true/, output)
    assert_match(/verification:\s+core_event_disposed/, output)

    sweep = ClickwrapTasks.digest_sweep
    assert_equal 1, sweep["documented_dispositions"].length
    assert_empty sweep["failed"]
  end

  test "clickwrap:verify treats a raw disposition marker as an unexplained mismatch" do
    Clickwrap::Event.where(id: @receipt.event_id).update_all(core_event_disposed_at: Clickwrap.now)

    sweep = ClickwrapTasks.digest_sweep

    assert_empty sweep["documented_dispositions"]
    assert_equal [@receipt.event_id], sweep["failed"]
    assert_equal :integrity_check_failed, Clickwrap.verify(@receipt.event_id).error
  end

  test "clickwrap:integrity:attest_missing records missing work and explains its delivery boundary" do
    adapter = TimestampAdapter.new
    Clickwrap.config.timestamp_receipts_with = adapter

    output = run_task("clickwrap:integrity:attest_missing")

    assert_match(/attempts made:\s+1/, output)
    assert_match(/results recorded:\s+1/, output)
    assert_match(/not exactly-once delivery/, output)
    assert_equal [@receipt.event.event_digest], adapter.digests
    assert @receipt.event.integrity_attestations.exists?(kind: "third_party_timestamp")

    rerun = run_task("clickwrap:integrity:attest_missing")
    assert_match(/attempts made:\s+0/, rerun)
    assert_equal 1, adapter.digests.length
  end

  test "clickwrap:reacceptance:plan previews who would be asked to act again" do
    submit_clickwrap(:current_terms, actor: @user, answers: { terms: "1" })

    output = run_task("clickwrap:reacceptance:plan", "POLICY" => "current_terms")

    assert_match(/Reacceptance plan for current_terms/, output)
    assert_match(/actors with current evidence:\s+1/, output)
    assert_match(/actors who would be asked again: 0/, output)

    # Whether a change is material is the application's call, and the task says
    # that rather than implying it decided.
    assert_match(/Clickwrap does not decide whether/, output)
  end

  test "clickwrap:holds:review lists holds in effect and the ones nobody revisited" do
    @receipt.place_on_legal_hold!(because: "Pending dispute 2026-184",
                                  placed_by: create_security_operator,
                                  review_at: 6.months.from_now)

    output = run_task("clickwrap:holds:review")

    assert_match(/in effect:\s+1/, output)
    assert_match(/past review date: 0/, output)
    assert_match(/A hold pauses scheduled disposition/, output)
  end

  # --- Disposition takes two steps -------------------------------------------

  test "clickwrap:retention:plan writes a reviewable plan and deletes nothing" do
    output = nil

    assert_difference -> { Clickwrap::DispositionPlan.count }, 1 do
      output = run_task("clickwrap:retention:plan", "BECAUSE" => "Scheduled retention run")
    end

    plan = Clickwrap::DispositionPlan.last

    assert_match(/Disposition plan #{plan.id}/, output)
    assert_match(/due:\s+0/, output)
    assert_match(/held:\s+0 \(a legal hold is pausing these\)/, output)
    assert_match(/unresolved:\s+0 \(a host event has not happened yet\)/, output)
    assert_match(/Nothing has been deleted/, output)
    assert_match(/clickwrap:retention:apply PLAN=#{plan.id}/, output)

    # The plan is a proposal with an expiry, and the evidence is untouched.
    assert_equal "open", plan.state
    assert Clickwrap::Event.exists?(id: @receipt.event_id)
    assert_not @receipt.event.reload.disposed?
    refute_prohibited_claims(output)
  end

  test "clickwrap:retention:apply refuses to run without the id of a reviewed plan" do
    task = Rake::Task["clickwrap:retention:apply"]
    task.reenable
    ENV.delete("PLAN")

    output = error = nil

    assert_difference -> { Clickwrap::Event.where(event_type: "disposition").count }, 0 do
      output, error = capture_io { assert_raises(SystemExit) { task.invoke } }
    end

    # There is no `--all` and no "apply whatever is due right now". A run nobody
    # reviewed is exactly the run that deletes the wrong set.
    assert_match(/PLAN is required/, error)
    assert_match(/run clickwrap:retention:plan first/, error)
    assert_empty output
  end

  private

  # Runs one task with the environment variables it reads, then puts the
  # environment back the way it was so the next test starts clean.
  def run_task(name, environment = {})
    Rake::Task["environment"].reenable
    task = Rake::Task[name]
    task.reenable

    previous = environment.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    environment.each { |key, value| ENV[key] = value.to_s }

    output, = capture_io { task.invoke }
    output
  ensure
    previous&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def refute_prohibited_claims(output)
    printed = output.downcase

    Clickwrap::Vocabulary::PROHIBITED_CLAIM_PHRASES.each do |phrase|
      assert_not_includes printed, phrase,
                          "a task printed #{phrase.inspect}, which is a legal determination no " \
                          "task may make on a host's behalf"
    end
  end
end
