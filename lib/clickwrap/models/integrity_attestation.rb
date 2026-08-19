# frozen_string_literal: true

module Clickwrap
  # One immutable result from an optional external integrity adapter. Merely
  # configuring an adapter is not evidence; this row records what was actually
  # submitted, what the provider returned, and whether its verifier checked the
  # exact event digest.
  class IntegrityAttestation < ApplicationRecord
    self.table_name = "clickwrap_integrity_attestations"
    self.record_timestamps = false

    KINDS = %w[event_anchor third_party_timestamp].freeze
    STATES = %w[verified issued_unverified unavailable failed].freeze

    belongs_to :event, class_name: "Clickwrap::Event", inverse_of: :integrity_attestations

    validates :kind, inclusion: { in: KINDS }
    validates :state, inclusion: { in: STATES }
    validates :event_id, :provider_name, :subject_digest, :attempted_at, :attestation_digest,
              presence: true

    before_validation :assign_attestation_digest, on: :create
    before_update :refuse_update
    before_destroy :refuse_destroy, prepend: true

    scope :verified, -> { where(state: "verified") }

    def verified?
      state == "verified" && verification.to_h["checked"] == true &&
        verification.to_h["verified"] == true && digest_verified?
    end

    def verified_for?(source_event)
      verified? && event_id.to_s == source_event.id.to_s &&
        subject_digest.to_s == source_event.event_digest.to_s &&
        (kind != "event_anchor" ||
          (chain_scope.to_s == source_event.chain_scope.to_s && chain_sequence == source_event.chain_sequence))
    end

    def digest_verified?
      Digest.secure_compare?(attestation_digest.to_s, compute_attestation_digest)
    end

    def canonical_fragment
      canonical_body.merge(
        "attestation_digest" => attestation_digest
      )
    end

    def canonical_body
      {
        "event_id" => event_id,
        "kind" => kind,
        "state" => state,
        "provider_name" => provider_name,
        "subject_digest" => subject_digest,
        "chain_scope" => chain_scope,
        "chain_sequence" => chain_sequence,
        "provider_reference" => provider_reference,
        "provider_result" => provider_result.presence,
        "verification" => verification.presence,
        "adapter_capabilities" => adapter_capabilities.presence,
        "attempted_at" => Receipt.format_time(attempted_at),
        "provider_reported_at" => Receipt.format_time(provider_reported_at),
        "created_at" => Receipt.format_time(created_at)
      }.compact
    end

    private

    def assign_attestation_digest
      self.attestation_digest ||= compute_attestation_digest
    end

    def compute_attestation_digest
      Digest.digest_canonical(canonical_body)
    end

    def refuse_update
      raise ImmutableEvidenceError,
            "Integrity attestations cannot be updated through Clickwrap. " \
            "Re-check a provider by recording a new attestation."
    end

    def refuse_destroy
      raise ImmutableEvidenceError,
            "Integrity attestations cannot be destroyed through Clickwrap."
    end
  end
end
