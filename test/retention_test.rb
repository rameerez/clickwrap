# frozen_string_literal: true

require "test_helper"

# Disposition is always two steps: plan, review, apply. These tests hold both
# halves to the promise the planner's own documentation makes — the plan deletes
# nothing and counts held and unresolved items separately, and the applier
# re-asks every question before it removes anything.
#
# The load-bearing case is the third one. `docs/PRD.md` §17 names the failure it
# exists to prevent: a fixed-duration job that treats "we cannot say yet" as "it
# is due now" and destroys regulated evidence before the host event that starts
# its clock has even happened.
class RetentionTest < ActiveSupport::TestCase
  setup do
    @user = create_user
    @operator = create_security_operator
  end

  # --- Planning ---------------------------------------------------------------

  test "a plan lists core events past their retention date and annex fields past theirs" do
    record_request_evidence_by_default!
    receipt = capture_clickwrap(:signup, actor: @user, http_request: fake_http_request)
    annex = receipt.event.reload.request_evidence

    # The core event keeps for six years; the recorded IP address and user agent
    # for ninety days. Seven years out both clocks have run out, which is the
    # point of keeping them on separate schedules in the first place.
    assert annex.ip_address_delete_after.present?

    travel_to 7.years.from_now do
      planner = Clickwrap::Retention::Planner.new(created_by: @operator, because: "Scheduled retention run")
      plan = planner.call

      parts = planner.due_items.select { |item| item.event_id == receipt.event_id }.map(&:part)
      assert_includes parts, :core_event
      assert_includes parts, :ip_address
      assert_includes parts, :browser_user_agent

      core = planner.due_items.find { |item| item.event_id == receipt.event_id && item.part == :core_event }
      assert_equal "recorded_schedule", core.rule
      assert_equal "ordinary_agreement_evidence", core.retention_class_key

      # A plan is a proposal. Nothing may be gone, marked, or altered by having
      # produced one — an operator has to be able to run this on a Friday.
      assert_equal plan.item_count, planner.due_items.length
      assert_not receipt.event.reload.disposed?
      assert annex.reload.recorded_ip_address?
    end
  end

  test "a plan excludes anything under a legal hold and reports the held count separately" do
    held = capture_clickwrap(:signup, actor: @user)
    ordinary = capture_clickwrap(:signup, actor: create_user)

    held.place_on_legal_hold!(because: "Pending dispute 2026-184", placed_by: @operator,
                              review_on: 6.months.from_now)

    travel_to 7.years.from_now do
      planner = Clickwrap::Retention::Planner.new(created_by: @operator)
      plan = planner.call
      summary = plan.summary.to_h

      assert_includes planner.due_items.map(&:event_id), ordinary.event_id
      assert_not_includes planner.due_items.map(&:event_id), held.event_id

      # Counted, not silently dropped. An operator who expected four thousand
      # items and sees twelve has to be able to tell a working hold from a
      # broken query.
      assert_equal [held.event_id], planner.held_items.map(&:event_id)
      assert_equal 1, summary["held"]
      assert_equal planner.due_items.length, summary["due"]
      assert_equal held.event_id, summary["held_examples"].first["event_id"]
    end
  end

  test "an event-based rule that has not resolved yet counts as unresolved and never as due" do
    # "Five years, or three years after this is liquidated, whichever is later"
    # has not started its clock until liquidation happens, and the host
    # calculation says so by returning nil.
    Clickwrap.configure do |config|
      config.calculate_retention_time_for(:regulated_evidence_retention_ends) { |_event| nil }
    end

    scheme = create_withdrawal(user: @user)
    receipt = capture_clickwrap(:driver_declaration, actor: @user, subject: scheme)

    assert_nil receipt.event.reload.retain_core_event_until
    assert_equal "regulated_evidence_retention_ends", receipt.event.retention_rule_name

    travel_to 50.years.from_now do
      planner = Clickwrap::Retention::Planner.new(created_by: @operator)
      plan = planner.call

      unresolved = planner.unresolved_items.find { |item| item.event_id == receipt.event_id }

      assert unresolved, "the event should be reported as unresolved rather than omitted"
      assert_equal :core_event, unresolved.part
      assert_equal "host_event:regulated_evidence_retention_ends", unresolved.rule
      assert_match(/has not resolved yet/, unresolved.detail)

      # Fifty years of elapsed time must not turn "we cannot say yet" into
      # "delete it now". This is the exact regression that destroys regulated
      # evidence early, so it is asserted three ways.
      assert_not_includes planner.due_items.map(&:event_id), receipt.event_id
      assert_not_includes plan.scope.to_h["items"].map { |item| item["event_id"] }, receipt.event_id
      assert_operator plan.summary.to_h["unresolved"], :>=, 1
    end
  end

  test "a plan never lists the presentation a receipt cites, and does list an abandoned one" do
    withdrawal = create_withdrawal(user: @user)
    abandoned = present_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal)
    receipt = capture_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
                                                          answers: { regulated_action: "1" })

    cited = Clickwrap::Presentation.find_by(nonce: receipt.event.presentation_manifest["nonce"])
    assert cited.accepted?

    travel_to 60.days.from_now do
      planner = Clickwrap::Retention::Planner.new(created_by: @operator)
      planner.call

      presentation_ids = planner.due_items.select { |item| item.part == :presentation }.map(&:record_id)

      # Both rows are past the thirty days this policy retains presentations
      # for. Only the one nobody ever submitted may be disposed of: the other is
      # the manifest the evidence cites.
      assert_includes presentation_ids, Clickwrap::Presentation.find_by(nonce: abandoned.manifest.nonce).id
      assert_not_includes presentation_ids, cited.id
    end
  end

  # --- Applying ---------------------------------------------------------------

  test "applying a plan disposes exactly what it listed and records every disposition" do
    record_request_evidence_by_default!
    receipt = capture_clickwrap(:signup, actor: @user, http_request: fake_http_request)

    travel_to 7.years.from_now do
      plan = Clickwrap::Retention::Planner.new(created_by: @operator,
                                               because: "Scheduled retention run").call
      # Every part except an unsubmitted presentation documents its own removal
      # with an appended event, so the count is knowable before the run.
      expected = plan.scope.to_h["items"].count { |item| item["part"] != "presentation" }
      result = nil

      assert_difference -> { Clickwrap::Event.where(event_type: "disposition").count }, expected do
        result = Clickwrap::Retention::Applier.new(plan, applied_by: @operator).call
      end

      assert result.clean?
      assert_equal plan.item_count, result.applied.length
      assert_empty result.skipped_held
      assert_empty result.skipped_changed

      annex = Clickwrap::RequestEvidence.find_by(event_id: receipt.event_id)
      assert annex.ip_address_was_deleted?
      assert_nil annex.ip_address
      assert receipt.event.reload.disposed?

      # The plan is single use: a second run is a run nobody reviewed.
      assert plan.reload.applied?
      assert_equal @operator.clickwrap_actor_reference, plan.applied_by_reference

      # And the reason travels onto the disposition events, so the deletion and
      # the review that authorized it can be read back together.
      assert_match(/Applied disposition plan #{plan.id}/,
                   Clickwrap::Event.where(event_type: "disposition").last.reason)
    end
  end

  test "applying a plan that expired or was already applied is refused by name" do
    capture_clickwrap(:signup, actor: @user)

    travel_to 7.years.from_now do
      applied = Clickwrap::Retention::Planner.new(created_by: @operator).call
      Clickwrap::Retention::Applier.new(applied, applied_by: @operator).call

      error = assert_raises(Clickwrap::DispositionPlanInvalid) do
        Clickwrap::Retention::Applier.new(applied, applied_by: @operator).call
      end
      assert_match(/already applied/, error.message)

      superseded = Clickwrap::Retention::Planner.new(created_by: @operator).call
      superseded.update!(state: "superseded")

      assert_raises(Clickwrap::DispositionPlanInvalid) do
        Clickwrap::Retention::Applier.new(superseded, applied_by: @operator).call
      end
    end

    stale = nil
    travel_to 7.years.from_now do
      stale = Clickwrap::Retention::Planner.new(created_by: @operator).call
    end

    # A plan names a set somebody reviewed at a moment in time. A day later that
    # set may not be the same set, so the plan stops being usable rather than
    # quietly deleting whatever it now matches.
    travel_to 7.years.from_now + Clickwrap::DispositionPlan::DEFAULT_LIFETIME + 1.minute do
      error = assert_raises(Clickwrap::DispositionPlanInvalid) do
        Clickwrap::Retention::Applier.new(stale, applied_by: @operator).call
      end

      assert_match(/expired/, error.message)
    end
  end

  test "a legal hold placed after the plan was reviewed stops that item at apply time" do
    receipt = capture_clickwrap(:signup, actor: @user)

    travel_to 7.years.from_now do
      plan = Clickwrap::Retention::Planner.new(created_by: @operator).call
      assert_includes plan.scope.to_h["items"].map { |item| item["event_id"] }, receipt.event_id

      receipt.place_on_legal_hold!(because: "Dispute raised after the plan was reviewed",
                                   placed_by: @operator, review_on: 6.months.from_now)

      result = Clickwrap::Retention::Applier.new(plan, applied_by: @operator).call
      skipped = result.skipped_held.find { |outcome| outcome.event_id == receipt.event_id }

      # The applier re-asks every question. A hold placed between the review and
      # the run wins, and the run says so rather than deleting silently.
      assert skipped, "the held item must be reported, not omitted"
      assert_match(/legal hold/, skipped.note)
      assert_not receipt.event.reload.disposed?
      assert_equal 1, result.counts["skipped_held"]
    end
  end

  test "an item whose retention rule no longer says it is due stops and is reported" do
    receipt = capture_clickwrap(:signup, actor: @user)

    travel_to 7.years.from_now do
      plan = Clickwrap::Retention::Planner.new(created_by: @operator).call

      # Somebody disposed of this by hand between the review and the run. The
      # applier finds the answer has changed and reports it instead of appending
      # a second disposition event for a disposition that already happened.
      Clickwrap::Retention::Disposition.dispose_core_event!(receipt.event,
                                                            because: "Disposed of by hand during review")

      result = Clickwrap::Retention::Applier.new(plan, applied_by: @operator).call
      changed = result.skipped_changed.find { |outcome| outcome.event_id == receipt.event_id }

      assert changed
      assert_match(/already disposed/, changed.note)
      assert result.clean?, "a changed answer is a skip, not an error"
    end
  end

  # --- Disposing the core event ----------------------------------------------

  test "disposing of a core event marks it disposed and leaves the row where it was" do
    receipt = capture_clickwrap(:signup, actor: @user)

    assert_difference -> { Clickwrap::Event.where(event_type: "disposition").count }, 1 do
      Clickwrap::Retention::Disposition.dispose_core_event!(receipt.event,
                                                            because: "The six-year period ended")
    end

    event = receipt.event.reload
    assert event.disposed?
    assert event.core_event_disposed_at.present?

    # An auditor must find a documented disposition rather than a hole where an
    # agreement used to be, so the row, its statements, and its documents stay.
    assert Clickwrap::Event.exists?(id: receipt.event_id)
    assert_equal 2, event.statements.count
    assert_equal 2, event.documents.count

    disposition = Clickwrap::Event.where(event_type: "disposition").last
    assert_equal receipt.event_id, disposition.predecessor_event_id
    assert_match(/The six-year period ended/, disposition.reason)

    # Disposing twice would put an event in the record describing nothing.
    assert_nil Clickwrap::Retention::Disposition.dispose_core_event!(event, because: "Running the job again")
  end

  test "disposing of a core event needs a reason and refuses while a legal hold is in effect" do
    receipt = capture_clickwrap(:signup, actor: @user)

    assert_raises(Clickwrap::LifecycleError) do
      Clickwrap::Retention::Disposition.dispose_core_event!(receipt.event, because: "   ")
    end

    receipt.place_on_legal_hold!(because: "Pending dispute 2026-184", placed_by: @operator,
                                 review_on: 6.months.from_now)

    # A hold that scheduled disposition could quietly step over would not be a
    # hold.
    assert_raises(Clickwrap::LegalHoldInEffect) do
      Clickwrap::Retention::Disposition.dispose_core_event!(receipt.event, because: "Retention period ended")
    end

    assert_not receipt.event.reload.disposed?
  end

  test "verifying a disposed core event says it was disposed of rather than that nothing happened" do
    receipt = capture_clickwrap(:signup, actor: @user)
    Clickwrap::Retention::Disposition.dispose_core_event!(receipt.event, because: "The six-year period ended")

    result = Clickwrap.verify(receipt.event_id)

    # "This was deleted on schedule" and "there is no evidence" are completely
    # different answers to give someone, and only one of them is true here.
    assert_not result.success?
    assert_equal :core_event_disposed, result.error
    assert_includes Clickwrap::Vocabulary::VERIFICATION_ERRORS, result.error
  end

  private

  # The initializer-level decision to record request evidence for every policy:
  # a purpose, a legal-basis reference, and a period, which is the least the
  # configuration will accept.
  def record_request_evidence_by_default!
    Clickwrap.configure do |config|
      config.record_ip_address_by_default = true
      config.reason_for_recording_ip_addresses_by_default = "Investigate account compromise"
      config.legal_basis_reference_for_recording_ip_addresses_by_default = "DUMMY-LIA-SECURITY-2026-01"
      config.delete_recorded_ip_addresses_after = 90.days

      config.record_browser_user_agent_by_default = true
      config.reason_for_recording_browser_user_agents_by_default = "Corroborate the client context"
      config.delete_recorded_browser_user_agents_after = 90.days
    end
  end

  def fake_http_request
    ActionDispatch::TestRequest.create(
      "REMOTE_ADDR" => "203.0.113.7",
      "HTTP_USER_AGENT" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Test/1.0",
      "action_dispatch.request_id" => "req-#{SecureRandom.hex(4)}"
    )
  end
end
