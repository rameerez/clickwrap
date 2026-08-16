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
    attr_reader :key, :statements, :retention_class_key, :request_evidence, :persist_presentations_for,
                :persist_presentations_because, :capture_channels, :locales, :authority_rule,
                :tenant_scope, :options, :snapshot, :revision

    def initialize(key:, statements:, retention_class_key: nil, request_evidence: nil,
                   persist_presentations_for: nil, persist_presentations_because: nil,
                   capture_channels: nil, locales: nil, tenant_scope: "optional",
                   authority_rule: nil, options: {})
      @key = key.to_s
      @statements = statements.freeze
      @retention_class_key = retention_class_key&.to_s
      @request_evidence = request_evidence || RequestEvidencePolicy.new(policy_key: @key)
      @persist_presentations_for = persist_presentations_for
      @persist_presentations_because = persist_presentations_because
      @capture_channels = (capture_channels || Vocabulary::CAPTURE_CHANNELS).map(&:to_s).freeze
      @locales = locales&.map(&:to_s)&.freeze
      @tenant_scope = tenant_scope.to_s
      @authority_rule = authority_rule
      @options = options.freeze

      validate!
      @snapshot = build_snapshot.freeze
      @revision = Digest.digest_canonical(@snapshot).freeze
      freeze
    end

    def statement(statement_key)
      statements.find { |statement| statement.key == statement_key.to_s }
    end

    def statement!(statement_key)
      statement(statement_key) || raise(
        UnknownStatementError,
        "Policy #{key} has no statement #{statement_key.inspect}. It declares: " \
        "#{statements.map(&:key).join(", ")}."
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
    def protected_outcome_statements = statements.select(&:record_protected_outcome_with)
    def protected_outcome_statement = protected_outcome_statements.first
    def records_protected_outcome? = protected_outcome_statement.present?

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

    def tenant_not_applicable? = tenant_scope == "not_applicable"
    def tenant_required? = tenant_scope == "required"
    def tenant_optional? = tenant_scope == "optional"

    # Resolves ambient controller context according to this policy. Personal
    # evidence deliberately discards a current organization; tenant-required
    # evidence fails before rendering if the host cannot supply one.
    def tenant_from_controller(candidate)
      return nil if tenant_not_applicable?

      validate_tenant!(candidate)
      candidate
    end

    # Direct service callers own their arguments, so an incompatible explicit
    # value is rejected instead of silently rewritten.
    def validate_tenant!(tenant)
      if tenant_not_applicable? && tenant.present?
        raise DefinitionError,
              "Policy #{key} says `tenant_is :not_applicable`, but this call supplied a tenant. " \
              "Remove `tenant:`; personal evidence must not change identity when the actor joins " \
              "or switches organizations."
      end

      if tenant_required? && tenant.nil?
        raise DefinitionError,
              "Policy #{key} says `tenant_is :required`, but this call supplied no tenant. Pass " \
              "the server-resolved tenant to presentation, capture, and verification."
      end

      true
    end

    # Delegation, guardianship, service-account action, and impersonation are
    # rejected unless the policy opts in and the host authority adapter agrees.
    # When permitted, the receipt keeps the authenticated principal, asserted
    # actor, and represented party as separate facts; Clickwrap does not decide
    # whether that authority is sufficient.
    def permits_acting_for? = options.fetch(:permit_acting_for, false) == true

    def permits_acting_for_party?(represented_party)
      permits_acting_for? && authority_rule&.permits?(represented_party)
    end

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
        "tenant_scope" => tenant_scope,
        "permit_exemptions" => permits_exemptions?,
        "permit_acting_for" => permits_acting_for?,
        "represented_party_authority" => authority_rule&.to_snapshot
      }.compact
    end

    def validate!
      validate_statements_present!
      validate_unique_statement_keys!
      validate_one_protected_outcome_recorder!
      validate_prerequisites!
      validate_retention!
      validate_persisted_presentations!
      validate_capture_channels!
      validate_tenant_scope!
      validate_authority_rule!
    end

    def validate_authority_rule!
      if permits_acting_for? && authority_rule.nil?
        raise DefinitionError,
              "Policy #{key} permits represented-party action without a compiled authority rule."
      end

      return unless authority_rule

      unless permits_acting_for?
        raise DefinitionError,
              "Policy #{key} has a represented-party authority rule but does not permit acting for another party."
      end

      return if authority_rule.adapter_name == "host"
      return if Clickwrap.config.represented_party_authority_adapter(authority_rule.adapter_name)

      raise DefinitionError,
            "Policy #{key} uses represented-party authority adapter " \
            "#{authority_rule.adapter_name.inspect}, but it is not registered. Register it with " \
            "`config.register_represented_party_authority`. Registered adapters: " \
            "#{Clickwrap.config.represented_party_authority_adapter_names.join(", ").presence || "(none)"}."
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
            "Policy #{key} declares #{duplicates.join(", ")} more than once. Two statements " \
            "with the same key would produce evidence nobody can tell apart."
    end

    def validate_one_protected_outcome_recorder!
      return if protected_outcome_statements.length <= 1

      raise DefinitionError,
            "Policy #{key} configures protected-outcome recorders on " \
            "#{protected_outcome_statements.map(&:key).join(", ")}. One protected action has one " \
            "result snapshot; put `record_protected_outcome_with:` on exactly one statement."
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
            "Policy #{key} allows unknown capture channels #{unknown.join(", ")}. " \
            "Choose from: #{Vocabulary::CAPTURE_CHANNELS.join(", ")}."
    end

    def validate_tenant_scope!
      return if %w[not_applicable optional required].include?(tenant_scope)

      raise DefinitionError,
            "Policy #{key} says `tenant_is #{tenant_scope.inspect}`. Choose `:not_applicable`, " \
            "`:optional`, or `:required`; Clickwrap will not guess whether ambient tenant context " \
            "belongs in an evidence identity."
    end
  end
end
