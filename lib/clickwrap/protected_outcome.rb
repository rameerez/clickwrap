# frozen_string_literal: true

module Clickwrap
  # Builds and verifies the exact result a protected database action records in
  # its evidence event. Hosts provide ordinary canonical facts; Clickwrap owns
  # the stable reference and the digest over the complete claim.
  #
  #   Clickwrap.protected_outcome(
  #     action: :submitted,
  #     record: withdrawal,
  #     state: withdrawal.status,
  #     facts: {
  #       amount_in_cents: withdrawal.amount_cents,
  #       currency: withdrawal.currency,
  #       destination_reference: withdrawal.destination_reference
  #     }
  #   )
  #
  # The fingerprint covers the action, record reference, state, and every fact.
  # It detects later changes to that snapshot; it is not a signature, identity
  # proof, trusted timestamp, or substitute for the linked domain record.
  module ProtectedOutcome
    REQUIRED_KEYS = %w[action facts fingerprint reference].freeze
    OPTIONAL_KEYS = %w[state].freeze
    PERMITTED_KEYS = (REQUIRED_KEYS + OPTIONAL_KEYS).freeze

    class << self
      def build(action:, record:, facts:, state: nil)
        action = required_string(action, "action")
        if record.respond_to?(:persisted?) && !record.persisted?
          raise ArgumentError,
                "A protected outcome needs a persisted `record:` with a stable reference. " \
                "Save the result inside the protected-action block and return it."
        end
        reference = Reference.record(record)
        if reference.blank?
          raise ArgumentError,
                "A protected outcome needs a persisted `record:` with a stable reference."
        end

        normalized_facts = normalize_facts(facts)
        claim = {
          "action" => action,
          "reference" => reference,
          "facts" => normalized_facts
        }
        claim["state"] = required_string(state, "state") unless state.nil?
        claim["fingerprint"] = fingerprint_for(claim)
        claim.freeze
      end

      def validate!(outcome)
        unless outcome.is_a?(Hash)
          raise DefinitionError,
                "A protected-outcome recorder must return `Clickwrap.protected_outcome(...)`, " \
                "which returns a Hash, but it returned #{outcome.class}."
        end

        normalized = outcome.deep_stringify_keys
        unknown = normalized.keys - PERMITTED_KEYS
        missing = REQUIRED_KEYS - normalized.keys
        if unknown.any? || missing.any?
          details = []
          details << "missing #{missing.join(", ")}" if missing.any?
          details << "unknown #{unknown.join(", ")}" if unknown.any?
          raise DefinitionError,
                "The protected outcome has #{details.join("; ")}. Build it with " \
                "`Clickwrap.protected_outcome(action:, record:, facts:, state: nil)` so its " \
                "meaning and fingerprint are complete."
        end

        required_string(normalized["action"], "action")
        required_string(normalized["reference"], "reference")
        required_string(normalized["state"], "state") if normalized.key?("state")
        normalized["facts"] = normalize_facts(normalized["facts"])

        expected = fingerprint_for(normalized.except("fingerprint"))
        unless Digest.secure_compare?(normalized["fingerprint"], expected)
          raise DefinitionError,
                "The protected outcome fingerprint does not match its action, record reference, " \
                "state, and facts. Build the outcome after the protected action finishes by " \
                "calling `Clickwrap.protected_outcome(...)`."
        end

        normalized
      rescue CanonicalJson::SerializationError => error
        raise DefinitionError,
              "Protected-outcome facts must be canonical JSON values: #{error.message}"
      end

      private

      def normalize_facts(facts)
        unless facts.is_a?(Hash) && facts.any?
          raise ArgumentError,
                "A protected outcome needs a non-empty `facts:` hash containing the exact " \
                "business facts the action committed."
        end

        normalized = facts.deep_stringify_keys
        CanonicalJson.generate(normalized)
        normalized
      end

      def fingerprint_for(claim)
        Digest.digest_canonical(claim)
      end

      def required_string(value, name)
        normalized = value.to_s
        return normalized if normalized.present?

        raise ArgumentError, "A protected outcome needs a non-blank `#{name}:`."
      end
    end
  end
end
