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

    def initialize(event)
      @event = event
      @committed = false
    end

    def event_id = event.id
    def policy_key = event.policy_key
    def recorded_at_by_server = event.recorded_at_by_server
    def actor_reference = event.actor_reference
    def subject_fingerprint = event.subject_fingerprint

    def statements
      event.statements.map { |statement| [statement.statement_key, statement.action] }.to_h
    end

    def committed? = @committed

    def to_canonical_json = refuse(:to_canonical_json)
    def to_html = refuse(:to_html)
    def verify = refuse(:verify)
    def export(*) = refuse(:export)

    def inspect = "#<Clickwrap::PendingReceipt #{event_id} (uncommitted)>"

    def to_s = event_id

    private

    def refuse(method_name)
      raise ReceiptNotCommitted,
            "##{method_name} is not available on a pending receipt. The transaction has not " \
            "committed yet, so there is nothing to #{method_name == :verify ? 'verify' : 'export'} " \
            "— and if the block raises, this event will never exist. Store `event_id` on your " \
            "domain row and use the Receipt that `capture_and!` returns."
    end
  end
end
