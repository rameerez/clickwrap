# frozen_string_literal: true

module Clickwrap
  # What `capture_and!` yields to the protected action, before anything has
  # committed.
  #
  # It carries the one thing the domain row legitimately needs — a stable
  # `event_id` to reference — and deliberately withholds everything else.
  # Export and verification are unavailable because there is nothing yet to
  # export or verify: the transaction may still roll back, and an object that
  # happily serialized itself into a receipt at this point would be describing
  # evidence that might never exist.
  #
  # If the transaction does roll back, this object becomes invalid rather than
  # continuing to look like a committed record.
  class PendingReceipt
    attr_reader :event

    def initialize(event, wait_for_outer_transaction: false)
      @event = event
      @wait_for_outer_transaction = wait_for_outer_transaction
      @committed = false
      @rolled_back = false
    end

    def event_id = event.id
    def policy_key = event.policy_key
    def recorded_at_by_server = event.recorded_at_by_server
    def actor_reference = event.actor_reference
    def subject_fingerprint = event.subject_fingerprint

    def statements
      event.statements.to_h { |statement| [statement.statement_key, statement.action] }
    end

    # Read the exact answer that this pending event accepted for one statement.
    # Protected domain work often needs it before commit: for example, an
    # optional consent can enable one preference while an unselected consent
    # must leave that preference disabled. Reaching through
    # `pending_receipt.event.statements` at every call site is both noisy and
    # dangerously easy to get wrong (an offered-but-unselected option is not a
    # grant).
    #
    # Unknown statement keys fail loudly so a typo cannot silently turn into a
    # false boolean at a consequential boundary.
    def answer_for(statement_key)
      statement_for(statement_key)&.answer
    end

    def answered?(statement_key)
      statement_for(statement_key)&.answered? || false
    end

    # Consent-oriented convenience predicates. They inspect BOTH the recorded
    # action and whether the person actually answered, so these methods never
    # reinterpret silence as a grant or decline.
    def granted?(statement_key)
      answered?(statement_key) && statement_for(statement_key).action == "granted"
    end

    def declined?(statement_key)
      answered?(statement_key) && statement_for(statement_key).action == "declined"
    end

    def committed?
      refresh_commit_state_if_possible!
      @committed
    end

    def rolled_back? = @rolled_back

    # Registers work that is only truthful after the real outer transaction
    # commits. Clickwrap's controller adapters use this to clear a registration
    # flow id without clearing it after a savepoint that later rolls back.
    def when_durably_committed(&callback)
      raise ArgumentError, "when_durably_committed needs a block" unless callback

      if committed?
        run_durable_commit_callback(callback)
      elsif !rolled_back?
        (@durable_commit_callbacks ||= []) << callback
      end

      self
    end

    # Once the real outermost transaction commits, this same object becomes a
    # truthful handle to the finalized receipt. This matters when Clickwrap
    # joins a host-owned transaction: the capture method has to return before
    # that outer transaction does, so returning a Receipt there would claim a
    # commit that has not happened yet.
    def receipt
      refuse(:receipt) unless committed?

      Receipt.find(event_id)
    end

    def to_canonical_json = refuse(:to_canonical_json)
    def to_html = refuse(:to_html)
    def verify = refuse(:verify)
    def export(*) = refuse(:export)

    def inspect
      state = if committed? then "committed"
              elsif rolled_back? then "rolled back"
              else "uncommitted"
              end

      "#<Clickwrap::PendingReceipt #{event_id} (#{state})>"
    end

    def to_s = event_id

    # Internal transaction callbacks. Public only because the Event callback
    # invokes them; downstream code gains no authority from calling them—the
    # receipt lookup still requires the event to exist after commit.
    def mark_committed!
      # A non-joinable outer transaction (most visibly Rails' transactional
      # test wrapper) can make a record-level after_commit fire at a savepoint.
      # That is not durable finality. Leave the handle pending until no database
      # transaction is open and the finalized row can be observed afresh.
      return self if @wait_for_outer_transaction && ::ActiveRecord::Base.connection.transaction_open?

      return self if @committed

      @committed = true
      @rolled_back = false
      run_durable_commit_callbacks
      self
    end

    def mark_rolled_back!
      @committed = false
      @rolled_back = true
      @durable_commit_callbacks = []
      self
    end

    private

    def statement_for(statement_key)
      # The policy lookup distinguishes an expected optional statement (which
      # legitimately has no event row when left unselected) from a misspelled
      # key. The former returns nil/false through the public helpers; the latter
      # raises with the policy builder's precise error.
      Clickwrap.policy!(policy_key).statement!(statement_key)
      event.statement(statement_key)
    end

    def refresh_commit_state_if_possible!
      return if @committed || @rolled_back || !@wait_for_outer_transaction
      return if ::ActiveRecord::Base.connection.transaction_open?

      mark_committed! if Event.where(id: event_id).where.not(event_digest: nil).exists?
    end

    def run_durable_commit_callbacks
      callbacks = Array(@durable_commit_callbacks)
      @durable_commit_callbacks = []
      callbacks.each { |callback| run_durable_commit_callback(callback) }
    end

    def run_durable_commit_callback(callback)
      callback.call
    rescue StandardError => error
      Clickwrap.report_after_commit_failure(error, event)
    end

    def refuse(method_name)
      status = rolled_back? ? "rolled back" : "has not committed yet"

      raise ReceiptNotCommitted,
            "##{method_name} is not available because this pending receipt #{status}. There is " \
            "no durable evidence to read until the real outermost database transaction commits."
    end
  end
end
