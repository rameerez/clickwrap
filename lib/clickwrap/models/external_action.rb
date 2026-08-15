# frozen_string_literal: true

module Clickwrap
  # The outbox row for an action Clickwrap cannot make atomic.
  #
  # Stripe, an identity provider, a timestamp authority: none of them can join
  # your database transaction, and pretending otherwise is how a provider
  # timeout becomes either a fictional success or a second debit. So the local
  # transaction commits a pending authorization and an idempotency key, the
  # provider is called outside it, and the outcome is appended back
  # idempotently.
  #
  # `unknown` is a first-class state, not an error state. A timeout is not a
  # failure — it is an absence of information — and the reconciliation task
  # exists precisely to resolve those later rather than guessing now.
  class ExternalAction < ApplicationRecord
    self.table_name = "clickwrap_external_actions"

    STATES = %w[pending succeeded failed unknown].freeze

    belongs_to :event, class_name: "Clickwrap::Event", inverse_of: :external_action

    validates :policy_key, :idempotency_key, :requested_at, presence: true
    validates :idempotency_key, uniqueness: true
    validates :state, inclusion: { in: STATES }

    scope :pending, -> { where(state: "pending") }
    scope :unresolved, -> { where(state: %w[pending unknown]) }
    scope :needing_reconciliation, lambda { |older_than = 15.minutes.ago|
      unresolved.where(requested_at: ...older_than)
    }

    def pending? = state == "pending"
    def resolved? = %w[succeeded failed].include?(state)

    # Each resolution is one idempotent local transaction. Calling it twice with
    # the same outcome is a no-op; calling it with a different outcome after the
    # action already resolved raises, because silently overwriting "succeeded"
    # with "failed" would rewrite the record of what the provider told us.
    def record_provider_success_and_consume!(provider_receipt = nil)
      resolve!("succeeded", provider_receipt: provider_receipt) do
        Lifecycle.consume_authorization!(event: event, because: "External action succeeded")
      end
    end

    def record_provider_failure!(reason:, provider_receipt: nil)
      resolve!("failed", provider_receipt: provider_receipt, failure_reason: reason)
    end

    # For the genuinely ambiguous case: the request may or may not have been
    # carried out, and the honest record says so rather than picking one.
    def record_provider_outcome_unknown!(reason:)
      resolve!("unknown", failure_reason: reason, resolved: false)
    end

    def to_s = "external action #{idempotency_key} (#{state})"

    private

    def resolve!(new_state, provider_receipt: nil, failure_reason: nil, resolved: true)
      transaction do
        reload.lock!

        return self if state == new_state

        if resolved? && new_state != state
          raise ExternalActionAlreadyResolved,
                "External action #{idempotency_key} already resolved as #{state}; it cannot " \
                "become #{new_state}. Appending a new event is the way to record a later change."
        end

        update!(
          state: new_state,
          provider_receipt: provider_receipt || self.provider_receipt,
          failure_reason: failure_reason,
          attempts: attempts + 1,
          resolved_at: resolved ? Clickwrap.now : nil
        )

        yield if block_given?
      end

      self
    end
  end
end
