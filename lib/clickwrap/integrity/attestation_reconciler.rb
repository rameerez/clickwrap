# frozen_string_literal: true

module Clickwrap
  module Integrity
    # Finds committed events for which a configured external integrity adapter
    # never left an attestation row, then asks only for those missing records.
    # This closes the recoverable part of the after-commit crash window: the
    # required evidence remains committed, and an operator can safely discover
    # and retry the optional external work later.
    #
    # No local database can prove whether a process died immediately before or
    # immediately after a provider accepted a request. Adapters should therefore
    # use the event digest (timestamps) or exact chain snapshot (anchors) as their
    # idempotency key. A retry may otherwise create a second valid provider
    # record; Clickwrap preserves both and never calls that exactly-once delivery.
    class AttestationReconciler
      Outcome = Data.define(:event_id, :kind, :state, :attestation_id) do
        def recorded? = attestation_id.present?

        def to_h
          {
            "event_id" => event_id,
            "kind" => kind,
            "state" => state,
            "attestation_id" => attestation_id
          }.compact
        end
      end

      Result = Data.define(:outcomes) do
        def attempted = outcomes.length
        def recorded = outcomes.count(&:recorded?)
        def not_recorded = attempted - recorded

        def counts
          { "attempted" => attempted, "recorded" => recorded, "not_recorded" => not_recorded }
        end

        def clean? = not_recorded.zero?
        def to_h = { "counts" => counts, "outcomes" => outcomes.map(&:to_h) }
      end

      class << self
        def missing_counts(scope: Event.all)
          configured_kinds.to_h do |kind|
            eligible = eligible_scope(scope, kind)
            recorded = IntegrityAttestation.where(kind: kind).select(:event_id)
            [kind, eligible.where.not(id: recorded).count]
          end
        end

        def configured_kinds
          kinds = []
          kinds << "third_party_timestamp" if Clickwrap.config.timestamp_receipts_with
          kinds << "event_anchor" if Clickwrap.config.anchor_event_history_with
          kinds
        end

        def eligible_scope(scope, kind)
          kind == "event_anchor" ? scope.where.not(chain_scope: nil) : scope
        end
      end

      def initialize(scope: Event.all, retry_failed_attestations: false)
        @scope = scope
        @retry_failed_attestations = retry_failed_attestations
      end

      attr_reader :scope, :retry_failed_attestations

      def call
        outcomes = []

        each_event do |event|
          configured_kinds_for(event).each do |kind|
            next unless attempt_needed?(event, kind)

            attestation = attest(event, kind)
            outcomes << Outcome.new(
              event_id: event.id,
              kind: kind,
              state: attestation&.state || "not_recorded",
              attestation_id: attestation&.id
            )
          end
        end

        Result.new(outcomes: outcomes.freeze)
      end

      private

      def each_event(&)
        scope.respond_to?(:find_each) ? scope.find_each(&) : scope.each(&)
      end

      def configured_kinds_for(event)
        self.class.configured_kinds.reject do |kind|
          kind == "event_anchor" && event.chain_scope.blank?
        end
      end

      def attempt_needed?(event, kind)
        latest = IntegrityAttestation.where(event_id: event.id, kind: kind).order(:attempted_at, :id).last
        latest.nil? || (retry_failed_attestations && latest.state == "failed")
      end

      def attest(event, kind)
        attestor = Attestor.new(event)
        kind == "event_anchor" ? attestor.anchor_event : attestor.timestamp_event
      end
    end
  end
end
