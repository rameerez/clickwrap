# frozen_string_literal: true

module Clickwrap
  # Rails normally defers a record's `after_commit` callback to the outermost
  # joinable transaction. A non-joinable outer transaction can instead make a
  # nested savepoint run that callback while the outer transaction is still
  # capable of rolling everything back. This tiny transaction record moves
  # Clickwrap's externally visible work to that real outer boundary.
  #
  # The transaction-record protocol is stable across every supported Rails
  # version (7.1 through 8.x), while the public
  # `ActiveRecord.after_all_transactions_commit` helper only exists from 7.2
  # and deliberately ignores non-joinable transactions.
  class DurableCommitCallback
    def self.defer(event)
      callback = new(event)
      ::ActiveRecord::Base.connection.add_transaction_record(callback)
      callback
    end

    def initialize(event)
      @event = event
    end

    def before_committed!; end

    def committed!(should_run_callbacks: true)
      @event.finalize_durable_commit! if should_run_callbacks
    end

    def rolledback!(force_restore_state: false, should_run_callbacks: true)
      @event.invalidate_pending_receipts_after_rollback! if should_run_callbacks
    end

    def trigger_transactional_callbacks? = true
  end
end
