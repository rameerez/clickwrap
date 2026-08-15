# frozen_string_literal: true

require "test_helper"

# Real commits, including Rails' non-joinable outer transaction edge. A
# transactional test wrapper can never prove an after-commit promise because it
# deliberately never reaches one.
class DurableCommitTest < ActiveSupport::TestCase
  use_real_database_commits!

  class RaisingIntegrityAdapter
    attr_reader :calls

    def initialize
      @calls = []
    end

    def timestamp(digest)
      calls << ["timestamp", digest]
      raise "timestamp provider unavailable"
    end

    def anchor(chain_head)
      calls << ["anchor", chain_head.last_event_digest]
      raise "anchor provider unavailable"
    end

    def verify(*) = raise("verification must not run after a failed publication")

    def capabilities
      { name: "raising_test_integrity_adapter", available: false }
    end

    def provider_name = "raising_test_integrity_adapter"
  end

  setup do
    @user = create_user
    @committed_event_ids = []
    Clickwrap.config.after_event_is_committed =
      ->(event) { @committed_event_ids << event.id }
  end

  test "a non-joinable outer commit publishes the receipt and hook only at durable finality" do
    pending = nil

    ActiveRecord::Base.transaction(joinable: false) do
      pending = direct_capture

      assert_instance_of Clickwrap::PendingReceipt, pending
      refute pending.committed?
      assert_empty @committed_event_ids
      assert Clickwrap::Event.exists?(id: pending.event_id)
    end

    assert pending.committed?
    assert_equal pending.event_id, pending.receipt.event_id
    assert_equal [pending.event_id], @committed_event_ids
  end

  test "a non-joinable outer rollback invalidates the handle and emits no observer event" do
    pending = nil

    ActiveRecord::Base.transaction(joinable: false) do
      pending = direct_capture
      raise ActiveRecord::Rollback
    end

    refute pending.committed?
    assert pending.rolled_back?
    assert_empty @committed_event_ids
    refute Clickwrap::Event.exists?(id: pending.event_id)
    assert_raises(Clickwrap::ReceiptNotCommitted) { pending.receipt }
  end

  test "an observer exception is reported after commit and cannot undo evidence" do
    reported = []
    Clickwrap.config.after_event_is_committed = ->(_event) { raise "observer unavailable" }
    Clickwrap.config.report_after_commit_failure_with =
      ->(error, event) { reported << [error.message, event.id] }

    receipt = direct_capture

    assert_instance_of Clickwrap::Receipt, receipt
    assert Clickwrap::Event.exists?(id: receipt.event_id)
    assert_equal [["observer unavailable", receipt.event_id]], reported
  end

  test "timestamp and anchor outages are recorded after commit and cannot undo evidence" do
    adapter = RaisingIntegrityAdapter.new
    reported = []
    Clickwrap.config.chain_event_history_with = :sha256
    Clickwrap.config.timestamp_receipts_with = adapter
    Clickwrap.config.anchor_event_history_with = adapter
    Clickwrap.config.report_after_commit_failure_with =
      ->(error, event) { reported << [error.message, event.id] }

    receipt = direct_capture
    attempts = receipt.event.integrity_attestations.to_a

    assert Clickwrap::Event.exists?(id: receipt.event_id)
    assert_equal %w[event_anchor third_party_timestamp], attempts.map(&:kind).sort
    assert_equal %w[failed failed], attempts.map(&:state)
    assert attempts.all?(&:digest_verified?)
    assert_equal %w[anchor timestamp], adapter.calls.map(&:first).sort
    assert_equal ["anchor provider unavailable", "timestamp provider unavailable"],
                 reported.map(&:first).sort
    assert_equal [receipt.event_id], reported.map(&:last).uniq
  end

  test "an outer rollback runs neither integrity adapter nor observer" do
    adapter = RaisingIntegrityAdapter.new
    Clickwrap.config.chain_event_history_with = :sha256
    Clickwrap.config.timestamp_receipts_with = adapter
    Clickwrap.config.anchor_event_history_with = adapter
    pending = nil

    ActiveRecord::Base.transaction(joinable: false) do
      pending = direct_capture
      raise ActiveRecord::Rollback
    end

    assert pending.rolled_back?
    assert_empty adapter.calls
    assert_empty @committed_event_ids
    assert_equal 0, Clickwrap::IntegrityAttestation.count
    assert_not Clickwrap::Event.exists?(id: pending.event_id)
  end

  test "a failure reporter that raises remains isolated after durable commit" do
    Clickwrap.config.after_event_is_committed = ->(_event) { raise "observer unavailable" }
    Clickwrap.config.report_after_commit_failure_with = ->(*) { raise "reporter unavailable" }

    receipt = nil
    assert_nothing_raised { receipt = direct_capture }

    assert Clickwrap::Event.exists?(id: receipt.event_id)
    assert receipt.event.digest_verified?
  end

  test "an attestation-write outage is reported but cannot undo a committed event" do
    adapter = RaisingIntegrityAdapter.new
    reported = []
    Clickwrap.config.timestamp_receipts_with = adapter
    Clickwrap.config.report_after_commit_failure_with =
      ->(error, event) { reported << [error.class.name, error.message, event.id] }
    Clickwrap::IntegrityAttestation.stubs(:create!).raises(
      ActiveRecord::StatementInvalid.new("attestation database write unavailable")
    )

    receipt = direct_capture

    assert Clickwrap::Event.exists?(id: receipt.event_id)
    assert_equal 0, Clickwrap::IntegrityAttestation.count
    assert_equal ["ActiveRecord::StatementInvalid", "RuntimeError"], reported.map(&:first).sort
    assert_equal [receipt.event_id], reported.map(&:last).uniq

    # Once the local write path is healthy again, the missing-attempt scan finds
    # the committed event and records a fresh immutable outcome. It cannot know
    # whether an earlier provider call succeeded before the process/database
    # failed, which is why adapters receive the digest as their idempotency key.
    Clickwrap::IntegrityAttestation.unstub(:create!)
    reconciliation = Clickwrap.reconcile_missing_integrity_attestations!

    assert_equal 1, reconciliation.attempted
    assert_equal 1, reconciliation.recorded
    assert_equal "failed", receipt.event.integrity_attestations.last.state
  end

  private

  def direct_capture
    presentation = present_clickwrap(:signup, actor: @user)
    Clickwrap.capture!(
      :signup,
      actor: @user,
      submission: submission_for(
        presentation,
        { terms: "1", privacy_notice: "1" }
      )
    )
  end
end
