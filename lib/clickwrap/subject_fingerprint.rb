# frozen_string_literal: true

module Clickwrap
  # One implementation of the aggregate subject fingerprint used by
  # presentation, remediation, capture, and verification. A security binding
  # implemented four nearly-identical ways eventually becomes four different
  # bindings; this is deliberately the only path.
  module SubjectFingerprint
    module_function

    def for(policy, subject)
      fingerprints = policy.statements.filter_map do |statement|
        next unless statement.subject_bound?

        [statement.key, for_statement(statement, subject)]
      end.to_h

      fingerprints.empty? ? nil : Digest.digest_canonical(fingerprints)
    end

    def for_statement(statement, subject)
      return nil if subject.nil?

      value = statement.subject_fingerprint_with.call(subject)
      value.nil? ? nil : Digest.digest(value.to_s)
    end
  end
end
