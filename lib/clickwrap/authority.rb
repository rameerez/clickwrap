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
    :required_permission,
    :allow_represented_party_creation
  ) do
    def initialize(represented_party_types: [], adapter_name: :host,
                   minimum_role: nil, required_permission: nil,
                   allow_represented_party_creation: false)
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
        required_permission: required_permission&.to_s,
        allow_represented_party_creation: allow_represented_party_creation == true
      )
    end

    def allows_represented_party_creation? = allow_represented_party_creation == true

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
        "when_actor_has_permission" => required_permission,
        "including_when_this_action_creates_the_represented_party" =>
          allows_represented_party_creation?
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

    def to_snapshot
      {
        "state" => authorized? ? "verified" : "not_verified",
        "source" => source,
        "role" => role,
        "verified_at" => verified_at&.iso8601(6),
        "details" => details.presence
      }.compact
    end

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

  # One fail-closed path for presentation-time and capture-time authority
  # checks. The represented-party adapter owns the authorization fact;
  # Clickwrap only validates that an affirmative decision carries enough
  # provenance to become meaningful evidence.
  class AuthorityVerifier
    def self.verify!(policy:, actor:, represented_party:, tenant:, authentication_context:)
      unless policy.permits_acting_for_party?(represented_party)
        raise AuthorityNotVerified,
              "Policy #{policy.key} does not permit an actor to act for " \
              "#{represented_party.class.name}. Declare the represented-party type and a " \
              "reviewed server-side authority rule."
      end

      rule = policy.authority_rule
      adapter = Clickwrap.config.represented_party_authority_adapter(rule.adapter_name)
      raw = if adapter
              adapter.verify(
                actor: actor,
                represented_party: represented_party,
                authority_rule: rule,
                tenant: tenant,
                authentication_context: authentication_context
              )
            else
              Clickwrap.config.verify_actor_can_act_for_represented_party_with.call(
                actor: actor,
                represented_party: represented_party,
                policy: policy,
                tenant: tenant,
                authentication_context: authentication_context
              )
            end
      decision = AuthorityDecision.from(raw)

      unless decision.authorized?
        raise AuthorityNotVerified,
              "The host authority check did not authorize this actor to act for the represented party."
      end

      missing = %i[source role verified_at].select { |attribute| decision.public_send(attribute).blank? }
      return decision if missing.empty?

      raise AuthorityNotVerified,
            "An authorized represented-party action must record #{missing.join(", ")}. Return " \
            "those facts from `verify_actor_can_act_for_represented_party_with`."
    end
  end
end
