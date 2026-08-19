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

    before_update :refuse_ordinary_update
    before_destroy :refuse_destroy, prepend: true

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

        if state == new_state
          return self if same_provider_resolution?(
            provider_receipt: provider_receipt,
            failure_reason: failure_reason
          )

          # Unknown is an observation, not a terminal result. A later
          # reconciliation attempt may still be unknown for a different
          # documented reason; append that attempt instead of erasing the first.
          unless new_state == "unknown"
            raise ExternalActionAlreadyResolved,
                  "External action #{idempotency_key} is already #{state}, but the repeated provider " \
                  "result carries different evidence. The original outcome is not silently overwritten."
          end
        end

        if resolved? && new_state != state
          raise ExternalActionAlreadyResolved,
                "External action #{idempotency_key} already resolved as #{state}; it cannot " \
                "become #{new_state}. Appending a new event is the way to record a later change."
        end

        update_columns(
          state: new_state,
          provider_receipt: provider_receipt || self.provider_receipt,
          failure_reason: failure_reason,
          attempt_count: attempt_count + 1,
          resolved_at: resolved ? Clickwrap.now : nil,
          updated_at: Clickwrap.now
        )

        Lifecycle.append_lifecycle_event!(
          event: event,
          event_type: "provider_outcome",
          reason: provider_outcome_reason(new_state, failure_reason),
          extra: {
            protected_outcome: {
              "external_action" => {
                "external_action_id" => id.to_s,
                "idempotency_key" => idempotency_key,
                "provider_name" => provider_name,
                "state" => new_state,
                "provider_receipt" => provider_receipt,
                "failure_reason" => failure_reason
              }.compact
            }
          }
        )

        yield if block_given?
      end

      self
    end

    def provider_outcome_reason(new_state, failure_reason)
      ["External action was recorded as #{new_state}.", failure_reason].compact.join(" ")
    end

    def same_provider_resolution?(provider_receipt:, failure_reason:)
      receipt_matches = provider_receipt.nil? ||
                        canonical_value(provider_receipt) == canonical_value(self.provider_receipt)
      reason_matches = failure_reason.to_s == self.failure_reason.to_s

      receipt_matches && reason_matches
    end

    def canonical_value(value)
      CanonicalJson.generate(value)
    rescue CanonicalJson::SerializationError
      value
    end

    def refuse_ordinary_update
      raise ImmutableEvidenceError,
            "External action outcomes are changed only through the named provider-result methods."
    end

    def refuse_destroy
      raise ImmutableEvidenceError,
            "External actions are durable outbox records and cannot be destroyed."
    end
  end
end
