# frozen_string_literal: true

module Clickwrap
  # One act inside a policy: a single thing the person is asked to do, with the
  # lifecycle its kind actually needs.
  #
  # A policy can contain several statements — "agree to the Terms" and
  # "acknowledge the Privacy Notice" typically appear on the same screen. They
  # produce one event and one receipt, but they never collapse into one
  # meaning: each statement keeps its own kind, documents, assertion, answer,
  # and lifecycle. That distinction is the whole point of the six kinds, and
  # flattening it is exactly the mistake this gem exists to stop.
  class Statement
    attr_reader :key, :kind, :ordinal, :document_keys, :assertion, :label,
                :link_labels, :choices, :purpose_key, :withdrawal_path,
                :valid_for, :requires, :subject_fingerprint_with,
                :subject_fingerprint_version, :record_protected_outcome_with,
                :protected_outcome_version, :options

    def initialize(key:, kind:, ordinal:, options: {})
      @key = key.to_s
      @kind = kind.to_s
      @ordinal = ordinal
      @options = options

      @document_keys = Array(options[:document]).map(&:to_s)
      @assertion = LocalizedText.new(options[:statement])
      @label = LocalizedText.new(options[:label])
      @link_labels = build_link_labels(options[:link_label])
      @choices = normalize_choices(options[:choices])
      @purpose_key = (options[:purpose] || key).to_s
      @withdrawal_path = options[:withdrawal_path]
      @valid_for = options[:valid_for]
      @requires = Array(options[:requires]).map(&:to_s)
      @subject_fingerprint_with = options[:subject_fingerprint_with]
      @subject_fingerprint_version = options[:subject_fingerprint_version]&.to_s
      @record_protected_outcome_with = options[:record_protected_outcome_with]
      @protected_outcome_version = options[:protected_outcome_version]&.to_s

      validate!
      freeze
    end

    # Optional statements are offered but never required. Leaving an optional
    # consent control unselected creates no grant at all — silence is not a
    # refusal, and the receipt says the option was offered and not taken rather
    # than recording a decision the person did not make.
    def optional? = options.fetch(:optional, false) == true
    def required? = !optional?

    # A statement that must be answered one way or the other, with real
    # unselected controls for each choice. Use it when the application needs a
    # recorded decision rather than the absence of one.
    def requires_an_explicit_choice? = options.fetch(:require_an_explicit_choice, false) == true

    def one_time? = options.fetch(:one_time, false) == true

    # When true, evidence against an older published version no longer
    # satisfies this statement. The application decides which change is
    # material; Clickwrap only enforces the rule it is given.
    def requires_current_version? = options.fetch(:require_current_version, false) == true

    def subject_bound? = !subject_fingerprint_with.nil?
    def initial_action = Vocabulary.initial_action_for(kind)
    def withdrawable? = Vocabulary.withdrawable?(kind)
    def expirable? = Vocabulary.expirable?(kind)
    def correctable? = Vocabulary.correctable?(kind)

    def expires_after(from)
      return nil unless valid_for

      from + valid_for
    end

    # Resolves every human-facing string for one locale. Called when the
    # presentation is built; the resolved text is what gets stored.
    def resolve_copy(locale:)
      {
        "assertion" => assertion.resolve(locale:).first,
        "label" => label.resolve(locale:).first,
        "link_labels" => link_labels.transform_values { |text| text.resolve(locale:).first }
      }
    end

    def to_snapshot
      {
        "key" => key,
        "kind" => kind,
        "ordinal" => ordinal,
        "documents" => document_keys,
        "assertion" => assertion.to_snapshot,
        "label" => label.to_snapshot,
        "link_labels" => link_labels.transform_values(&:to_snapshot),
        "choices" => choices,
        "required" => required?,
        "optional" => optional?,
        "requires_an_explicit_choice" => requires_an_explicit_choice?,
        "requires_current_version" => requires_current_version?,
        "one_time" => one_time?,
        "purpose_key" => purpose_key,
        "withdrawal_path" => withdrawal_path,
        "valid_for_seconds" => valid_for&.to_i,
        "requires" => requires,
        "subject_fingerprint_with" => subject_fingerprint_with ? "configured" : nil,
        "subject_fingerprint_version" => subject_fingerprint_version,
        "record_protected_outcome_with" => record_protected_outcome_with ? "configured" : nil,
        "protected_outcome_version" => protected_outcome_version
      }.compact
    end

    private

    def build_link_labels(declaration)
      case declaration
      when nil then {}
      when String, Symbol then { document_keys.first.to_s => LocalizedText.new(declaration) }
      when Hash then declaration.to_h { |key, value| [key.to_s, LocalizedText.new(value)] }
      else
        raise DefinitionError,
              "`link_label:` on statement #{key} must be text or a hash of document key to text"
      end
    end

    # Choices are written as { yes: :grant, no: :decline } so the policy states
    # both what the person can pick and what each pick means. A choice whose
    # meaning is not one of the kind's actions would produce an event action
    # nothing downstream can interpret.
    def normalize_choices(declaration)
      return nil if declaration.nil?

      unless declaration.is_a?(Hash)
        raise DefinitionError,
              "`choices:` on statement #{key} must be a hash of choice name to meaning, " \
              "for example { yes: :grant, no: :decline }"
      end

      declaration.to_h { |choice, meaning| [choice.to_s, meaning.to_s] }.freeze
    end

    def validate!
      unless Vocabulary.kind?(kind)
        raise DefinitionError, "#{kind.inspect} is not one of: #{Vocabulary::KINDS.join(", ")}"
      end

      validate_assertion!
      validate_lifecycle!
      validate_versioned_callbacks!
      validate_choices!
      validate_consent!
    end

    def validate_assertion!
      return if assertion.present?

      raise DefinitionError,
            "Statement #{key} has no assertion text. Give it `statement:` with the exact " \
            "first-person sentence the server should include in its offer, because that is what " \
            "the receipt records."
    end

    def validate_lifecycle!
      if valid_for && !expirable?
        raise DefinitionError,
              "Statement #{key} is #{kind}, which does not expire, but it declares " \
              "`valid_for:`. Agreements and attestations are superseded by new versions or " \
              "corrections instead."
      end

      if one_time? && !Vocabulary.one_time_allowed?(kind)
        raise DefinitionError,
              "Statement #{key} is #{kind}, but `one_time:` only makes sense for an " \
              "authorization bound to a single protected action."
      end

      return unless Vocabulary.one_time_allowed?(kind) && one_time? && valid_for.nil?

      raise DefinitionError,
            "One-time authorization #{key} has no `valid_for:`. An authorization that never " \
            "expires and is never consumed would stay usable indefinitely; say how long it is " \
            "good for."
    end

    def validate_choices!
      return if choices.nil?

      # Choices belong to the initial act. Lifecycle actions such as consumed,
      # revoked, superseded, or corrected are server-authored transitions and
      # must never become meanings a browser can choose in a capture.
      permitted = [initial_action]
      permitted.push("grant", "decline") if kind == "consent"
      unknown = choices.values.reject { |meaning| permitted.include?(meaning) }
      return if unknown.empty?

      raise DefinitionError,
            "Statement #{key} maps a choice to #{unknown.join(", ")}, which is not something a " \
            "#{kind} can record. Use one of: #{permitted.uniq.join(", ")}."
    end

    # Proc bodies cannot be serialized into a frozen policy revision. Requiring
    # a human-chosen version makes a behavior change visible in the revision
    # digest and lets capture reject an old presentation whose executable
    # callback no longer exists under the same meaning.
    def validate_versioned_callbacks!
      if subject_fingerprint_with && subject_fingerprint_version.to_s.strip.empty?
        raise DefinitionError,
              "Statement #{key} configures `subject_fingerprint_with:` but gives no " \
              "`subject_fingerprint_version:`. Name the callback contract (for example " \
              '"covered-rides-v1") and change that name whenever its behavior changes.'
      end

      return unless record_protected_outcome_with && protected_outcome_version.to_s.strip.empty?

      raise DefinitionError,
            "Statement #{key} configures `record_protected_outcome_with:` but gives no " \
            "`protected_outcome_version:`. Name the callback contract and change that name " \
            "whenever the recorded outcome shape or meaning changes."
    end

    def validate_consent!
      return unless kind == "consent"

      if withdrawal_path.nil?
        raise DefinitionError,
              "Consent statement #{key} has no `withdrawal_path:`. Consent that cannot be " \
              "withdrawn as easily as it was given is not something Clickwrap will record as " \
              "consent. Point it at the page where someone can change their mind."
      end

      return unless requires_an_explicit_choice? && choices.nil?

      raise DefinitionError,
            "Consent statement #{key} requires an explicit choice but declares no `choices:`. " \
            "Give it the options the person will actually see."
    end
  end
end
