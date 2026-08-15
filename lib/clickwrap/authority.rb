# frozen_string_literal: true

module Clickwrap
  AUTHORITY_DECISION_ATTRIBUTES = %i[authorized source role verified_at details].freeze

  # Namespace marker for authority adapters and future helpers. The public
  # immutable value objects remain Clickwrap::AuthorityRule and
  # Clickwrap::AuthorityDecision for the shortest host-facing API.
  module Authority
  end

  # The server-owned rule that says which represented parties a policy allows
  # and which adapter has to establish the actor's authority. It is compiled
  # into the policy revision and repeated in the signed presentation, so a
  # browser cannot choose a weaker role or a different authority source.
  AuthorityRule = Data.define(
    :represented_party_types,
    :adapter_name,
    :minimum_role,
    :required_permission
  ) do
    def initialize(represented_party_types: [], adapter_name: :host,
                   minimum_role: nil, required_permission: nil)
      normalized_types = Array(represented_party_types).filter_map do |type|
        name = type.is_a?(Class) ? type.name : type.to_s
        name unless name.strip.empty?
      end.uniq.freeze

      if normalized_types.empty?
        raise DefinitionError,
              "A represented-party authority rule must name at least one represented-party " \
              "class. An empty list would let the rule authorize every kind of record."
      end

      super(
        represented_party_types: normalized_types,
        adapter_name: adapter_name.to_s,
        minimum_role: minimum_role&.to_s,
        required_permission: required_permission&.to_s
      )
    end

    def permits?(represented_party)
      return false if represented_party.nil?

      represented_party.class.ancestors.any? do |ancestor|
        ancestor.respond_to?(:name) && represented_party_types.include?(ancestor.name)
      end
    end

    def to_snapshot
      {
        "represented_party_types" => represented_party_types,
        "authority_adapter" => adapter_name,
        "when_actor_is_at_least" => minimum_role,
        "when_actor_has_permission" => required_permission
      }.compact
    end
  end

  # The host's answer to "may this actor act for that represented party?".
  # Clickwrap records the answer and its provenance; it does not decide whether
  # the authority is legally sufficient.
  AuthorityDecision = Data.define(:authorized, :source, :role, :verified_at, :details) do
    def initialize(authorized: false, source: nil, role: nil, verified_at: nil, details: {})
      super(
        authorized: authorized == true,
        source: source&.to_s,
        role: role&.to_s,
        verified_at: verified_at,
        details: (details || {}).to_h.deep_stringify_keys.freeze
      )
    end

    def authorized? = authorized == true

    def self.from(value)
      return value if value.is_a?(self)

      if value == true
        raise ConfigurationError,
              "The represented-party authority callback returned bare true. Return a " \
              "Clickwrap::AuthorityDecision (or a hash) with `authorized:`, `source:`, " \
              "`role:`, and `verified_at:` so the evidence records why the actor was authorized."
      end

      return new(authorized: false) if value.nil? || value == false

      unless value.respond_to?(:to_h)
        raise ConfigurationError,
              "The represented-party authority callback must return false, nil, a " \
              "Clickwrap::AuthorityDecision, or a hash with `authorized:`, `source:`, " \
              "`role:`, and `verified_at:`. It returned #{value.class.name}."
      end

      attributes = value.to_h.symbolize_keys
      unknown = attributes.keys - AUTHORITY_DECISION_ATTRIBUTES
      if unknown.any?
        label = unknown.one? ? "attribute" : "attributes"
        raise ConfigurationError,
              "The represented-party authority callback returned unknown #{label} " \
              "#{unknown.map { |key| "`#{key}:`" }.join(", ")}. Supported attributes are " \
              "#{AUTHORITY_DECISION_ATTRIBUTES.map { |key| "`#{key}:`" }.join(", ")}."
      end

      new(**attributes)
    end
  end
end
