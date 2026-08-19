# frozen_string_literal: true

module Clickwrap
  module Integrity
    # Invokes optional external adapters only after the required event commit.
    # An outage can never roll back the protected action; every ordinary result
    # is persisted, and an exception is reported through the host's existing
    # after-commit failure hook.
    class Attestor
      ChainSnapshot = Data.define(:chain_scope, :sequence, :last_event_id, :last_event_digest) do
        def checkpoint_digest = last_event_digest
      end

      def self.attest_after_commit(event) = new(event).attest_after_commit

      def initialize(event)
        @event = event
      end

      attr_reader :event

      def attest_after_commit
        timestamp_event if Clickwrap.config.timestamp_receipts_with
        anchor_event if Clickwrap.config.anchor_event_history_with && event.chain_scope.present?
      end

      def timestamp_event
        adapter = Clickwrap.config.timestamp_receipts_with
        attempted_at = Clickwrap.now
        token = adapter.timestamp(event.event_digest)
        token_body = normalized_result(token)
        token_digest = token_body["digest"]

        unless token_digest.to_s == event.event_digest.to_s
          return record!(
            kind: "third_party_timestamp", state: "failed", adapter: adapter,
            attempted_at: attempted_at, provider_result: token_body,
            verification: { "checked" => false, "verified" => false,
                            "detail" => "The provider result named a different digest." }
          )
        end

        verification = if token_body["issued"] == true
                         normalized_result(adapter.verify(token_body["token"], event.event_digest))
                       else
                         { "checked" => false, "verified" => false,
                           "detail" => token_body["detail"] }
                       end

        record!(
          kind: "third_party_timestamp",
          state: attestation_state(token_body["issued"], verification),
          adapter: adapter,
          attempted_at: attempted_at,
          provider_result: token_body,
          verification: verification,
          provider_reference: token_body["token_reference"],
          provider_reported_at: parse_time(token_body["provider_reported_time"])
        )
      rescue StandardError => error
        record_exception(kind: "third_party_timestamp", adapter: adapter,
                         attempted_at: attempted_at, error: error)
      end

      def anchor_event
        adapter = Clickwrap.config.anchor_event_history_with
        attempted_at = Clickwrap.now
        snapshot = ChainSnapshot.new(
          chain_scope: event.chain_scope,
          sequence: event.chain_sequence,
          last_event_id: event.id,
          last_event_digest: event.event_digest
        )
        publication = normalized_result(adapter.anchor(snapshot))
        verification = if publication["anchored"] == true
                         # Verification receives the exact publication result
                         # as well as the expected chain head. An adapter that
                         # merely re-reads "some current head" cannot prove the
                         # reference stored beside this attestation is the one
                         # it actually checked.
                         normalized_result(adapter.verify(publication, snapshot))
                       else
                         { "checked" => false, "verified" => false,
                           "detail" => publication["detail"] }
                       end

        record!(
          kind: "event_anchor",
          state: attestation_state(publication["anchored"], verification),
          adapter: adapter,
          attempted_at: attempted_at,
          provider_result: publication,
          verification: verification,
          provider_reference: publication["reference"],
          provider_reported_at: parse_time(publication["published_at"]),
          chain_scope: event.chain_scope,
          chain_sequence: event.chain_sequence
        )
      rescue StandardError => error
        record_exception(kind: "event_anchor", adapter: adapter,
                         attempted_at: attempted_at, error: error,
                         chain_scope: event.chain_scope, chain_sequence: event.chain_sequence)
      end

      private

      def record!(kind:, state:, adapter:, attempted_at:, provider_result:, verification:,
                  provider_reference: nil, provider_reported_at: nil, chain_scope: nil, chain_sequence: nil)
        IntegrityAttestation.create!(
          event_id: event.id,
          kind: kind,
          state: state,
          provider_name: provider_name(adapter, provider_result),
          subject_digest: event.event_digest,
          chain_scope: chain_scope,
          chain_sequence: chain_sequence,
          provider_reference: provider_reference,
          provider_result: provider_result,
          verification: verification,
          adapter_capabilities: safe_capabilities(adapter),
          attempted_at: attempted_at,
          provider_reported_at: provider_reported_at,
          created_at: Clickwrap.now
        )
      end

      def attestation_state(issued, verification)
        return "unavailable" unless issued == true
        return "verified" if verification["checked"] == true && verification["verified"] == true

        "issued_unverified"
      end

      def provider_name(adapter, body)
        body["provider_name"].presence ||
          (adapter.respond_to?(:provider_name) ? adapter.provider_name.to_s : adapter.class.name)
      end

      def normalized_result(value)
        body = value.respond_to?(:to_h) ? value.to_h : value
        unless body.respond_to?(:to_h)
          raise ConfigurationError,
                "An integrity adapter must return a Hash-like result, got #{value.class}."
        end

        body.to_h.each_with_object({}) do |(key, nested), result|
          result[key.to_s] = normalize_value(nested)
        end
      end

      def normalize_value(value)
        case value
        when Hash then value.to_h { |key, nested| [key.to_s, normalize_value(nested)] }
        when Array then value.map { |nested| normalize_value(nested) }
        when Time, ActiveSupport::TimeWithZone then Receipt.format_time(value)
        else value
        end
      end

      def parse_time(value)
        return value if value.is_a?(Time)
        return nil if value.blank?

        Time.parse(value.to_s).utc
      rescue ArgumentError
        nil
      end

      def safe_capabilities(adapter)
        normalized_result(adapter.capabilities)
      rescue StandardError => error
        {
          "unavailable" => true,
          "error_class" => error.class.name,
          "detail" => "The adapter's capabilities could not be read."
        }
      end

      def record_exception(kind:, adapter:, attempted_at:, error:, chain_scope: nil, chain_sequence: nil)
        adapter_error = error
        IntegrityAttestation.create!(
          event_id: event.id,
          kind: kind,
          state: "failed",
          provider_name: safe_provider_name(adapter),
          subject_digest: event.event_digest,
          chain_scope: chain_scope,
          chain_sequence: chain_sequence,
          provider_result: {
            "error_class" => adapter_error.class.name,
            "detail" => adapter_error.message.to_s.slice(0, 1_000)
          },
          verification: {
            "checked" => false,
            "verified" => false,
            "detail" => "The adapter raised before this attestation could be verified."
          },
          adapter_capabilities: safe_capabilities(adapter),
          attempted_at: attempted_at,
          created_at: Clickwrap.now
        )
      rescue StandardError => error
        report_failure(error)
      ensure
        report_failure(adapter_error)
      end

      def safe_provider_name(adapter)
        value = adapter.provider_name if adapter.respond_to?(:provider_name)
        value.to_s.presence || adapter.class.name.presence || "unknown_integrity_adapter"
      rescue StandardError
        adapter.class.name.presence || "unknown_integrity_adapter"
      end

      def report_failure(error)
        Clickwrap.report_after_commit_failure(error, event)
        nil
      end
    end
  end
end
