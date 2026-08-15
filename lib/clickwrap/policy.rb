# frozen_string_literal: true

module Clickwrap
  # A compiled, frozen policy: what the server will present and what it will
  # accept back.
  #
  # The browser may answer a policy. It may never choose one. Policy key,
  # revision, document versions, validity, subject binding, retention, and
  # request-evidence fields are all resolved server-side and rechecked at
  # submit, because every one of them is a security decision and a form field
  # is not a safe place to keep one.
  #
  # A policy's `revision` is the digest of its compiled snapshot. Publishing
  # freezes that snapshot in the database the first time the policy is
  # presented or captured, so a receipt written today still explains itself
  # after the Ruby source has moved on. The digest covers declared structure and
  # copy; host lambdas (subject fingerprints, protected-outcome recorders) are
  # recorded as present rather than serialized, since their bodies cannot be
  # canonicalized. That boundary is stated in the receipt rather than papered
  # over.
  class Policy
    attr_reader :key, :statements, :retention_class_key, :request_evidence,
                :persist_presentations_for, :persist_presentations_because,
                :capture_channels, :locales, :options

    def initialize(key:, statements:, retention_class_key: nil, request_evidence: nil,
                   persist_presentations_for: nil, persist_presentations_because: nil,
                   capture_channels: nil, locales: nil, options: {})
      @key = key.to_s
      @statements = statements.freeze
      @retention_class_key = retention_class_key&.to_s
      @request_evidence = request_evidence || RequestEvidencePolicy.new(policy_key: @key)
      @persist_presentations_for = persist_presentations_for
      @persist_presentations_because = persist_presentations_because
      @capture_channels = (capture_channels || Vocabulary::CAPTURE_CHANNELS).map(&:to_s).freeze
      @locales = locales&.map(&:to_s)&.freeze
      @options = options.freeze

      validate!
      @snapshot = build_snapshot.freeze
      @revision = Digest.digest_canonical(@snapshot).freeze
      freeze
    end

    attr_reader :snapshot, :revision

    def statement(statement_key)
      statements.find { |statement| statement.key == statement_key.to_s }
    end

    def statement!(statement_key)
      statement(statement_key) || raise(
        UnknownStatementError,
        "Policy #{key} has no statement #{statement_key.inspect}. It declares: " \
        "#{statements.map(&:key).join(', ')}."
      )
    end

    def required_statements = statements.select(&:required?)
    def optional_statements = statements.select(&:optional?)
    def document_keys = statements.flat_map(&:document_keys).uniq
    def kinds = statements.map(&:kind).uniq

    def one_time_statements = statements.select(&:one_time?)
    def subject_bound? = statements.any?(&:subject_bound?)
    def consent_statements = statements.select { |statement| statement.kind == "consent" }
    def authorization_statements = statements.select { |statement| statement.kind == "authorization" }

    def persist_presentations? = !persist_presentations_for.nil?

    # Whether a system exemption may stand in for a human action under this
    # policy. It is off unless the policy says otherwise, and an exemption never
    # satisfies `agreed_to?` or any other human-action predicate even when it
    # is permitted — it answers `exempted_from?` instead.
    def permits_exemptions? = options.fetch(:permit_exemptions, false) == true

    def permits_capture_channel?(channel) = capture_channels.include?(channel.to_s)

    def permits_locale?(locale)
      locales.nil? || locales.include?(locale.to_s)
    end

    # Delegation, guardianship, service-account action, and impersonation are
    # rejected unless the policy opts in and the host authority adapter agrees.
    # When permitted, the receipt keeps the authenticated principal, asserted
    # actor, and represented party as separate facts; Clickwrap does not decide
    # whether that authority is sufficient.
    def permits_acting_for? = options.fetch(:permit_acting_for, false) == true

    def to_s = "Clickwrap policy #{key} (#{revision})"

    private

    def build_snapshot
      {
        "schema" => Clickwrap::CANONICAL_SCHEMA_VERSION,
        "policy" => key,
        "statements" => statements.map(&:to_snapshot),
        "retention_class" => retention_class_key,
        "request_evidence" => request_evidence.to_snapshot,
        "persist_presentations_for_seconds" => persist_presentations_for&.to_i,
        "persist_presentations_because" => persist_presentations_because,
        "capture_channels" => capture_channels,
        "locales" => locales,
        "permit_exemptions" => permits_exemptions?,
        "permit_acting_for" => permits_acting_for?
      }.compact
    end

    def validate!
      validate_statements_present!
      validate_unique_statement_keys!
      validate_prerequisites!
      validate_retention!
      validate_persisted_presentations!
      validate_capture_channels!
    end

    def validate_statements_present!
      return unless statements.empty?

      raise DefinitionError,
            "Policy #{key} declares no statements. A policy that asks for nothing records " \
            "nothing; add at least one `agree_to`, `acknowledge`, `consent_to`, `declare`, " \
            "`attest`, or `authorize`."
    end

    def validate_unique_statement_keys!
      duplicates = statements.map(&:key).tally.select { |_, count| count > 1 }.keys
      return if duplicates.empty?

      raise DefinitionError,
            "Policy #{key} declares #{duplicates.join(', ')} more than once. Two statements " \
            "with the same key would produce evidence nobody can tell apart."
    end

    # `requires:` says an authorization is only good when named statements were
    # made in the same submission, and in order. A prerequisite that does not
    # exist, or that comes later on the page, is a policy bug rather than a
    # runtime surprise.
    def validate_prerequisites!
      statements.each do |statement|
        statement.requires.each do |prerequisite_key|
          prerequisite = statement(prerequisite_key)

          unless prerequisite
            raise DefinitionError,
                  "Statement #{statement.key} in policy #{key} requires #{prerequisite_key}, " \
                  "which this policy does not declare."
          end

          next if prerequisite.ordinal < statement.ordinal

          raise DefinitionError,
                "Statement #{statement.key} in policy #{key} requires #{prerequisite_key}, " \
                "but that statement is declared after it. Prerequisites must come first, " \
                "because that is the order the person will be asked."
        end
      end
    end

    def validate_retention!
      return if retention_class_key

      raise DefinitionError,
            "Policy #{key} has no retention class. Add `retain_with :some_class` and define " \
            "that class with `Clickwrap.retention`. Clickwrap will not default your evidence " \
            "to forever, and it will not pick a period for you."
    end

    def validate_persisted_presentations!
      return unless persist_presentations?

      if persist_presentations_because.to_s.strip.empty?
        raise DefinitionError,
              "Policy #{key} persists presentations before submission but gives no `because:`. " \
              "Storing every render is more personal data than the default path; say why."
      end

      return if persist_presentations_for.to_i.positive?

      raise DefinitionError,
            "Policy #{key} persists presentations for #{persist_presentations_for.inspect}, " \
            "which is not a retention period."
    end

    def validate_capture_channels!
      unknown = capture_channels - Vocabulary::CAPTURE_CHANNELS
      return if unknown.empty?

      raise DefinitionError,
            "Policy #{key} allows unknown capture channels #{unknown.join(', ')}. " \
            "Choose from: #{Vocabulary::CAPTURE_CHANNELS.join(', ')}."
    end
  end
end
