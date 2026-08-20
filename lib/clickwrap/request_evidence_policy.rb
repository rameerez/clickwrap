# frozen_string_literal: true

module Clickwrap
  # What one policy is allowed to record about the HTTP request that carried a
  # capture.
  #
  # Everything here is off unless a policy or the initializer names it. That is
  # not squeamishness about useful data: it is that high-quality evidence is
  # purpose-specific. An IP address is personal data, and keeping it on your own
  # infrastructure does not remove the duty to have a reason for it, protect it,
  # and stop keeping it eventually. So each field is enabled by name, and the
  # policy that enables it is the server's, never the browser's.
  #
  # Naming a field is the whole requirement. Every recorded category still
  # leaves here carrying a purpose and a disposal posture, because a snapshot
  # read years from now has to answer both questions — but since 0.3.0 those
  # answers have honest gem-supplied defaults instead of being the entry fee. A
  # host who writes their own keeps their own words, and the privacy inventory
  # reports which of the two is looking back at you.
  #
  # None of these fields is identity or physical location. An IP address is a
  # network observation. IP geolocation is a provider's estimate about that
  # address. The raw User-Agent header is whatever the client chose to send.
  class RequestEvidencePolicy
    FIELD_CATEGORIES = %i[ip_address browser_user_agent ip_geolocation].freeze

    # One category's settings: whether to record it, why, how long, and what
    # happens when it cannot be resolved.
    Setting = Data.define(
      :record, :encrypted, :delete_after, :retain_until, :fail_if_unavailable,
      :because, :legal_basis_reference, :data_protection_impact_assessment_reference
    ) do
      def initialize(record: false, encrypted: nil, delete_after: nil, retain_until: nil,
                     fail_if_unavailable: false, because: nil, legal_basis_reference: nil,
                     data_protection_impact_assessment_reference: nil)
        super
      end

      def record? = record == true
      def encrypted? = encrypted == true
      def fail_if_unavailable? = fail_if_unavailable == true

      def to_snapshot
        {
          "record" => record?,
          "encrypted" => encrypted?,
          "delete_after_seconds" => delete_after&.to_i,
          "retain_until_rule" => retain_until&.to_s,
          "fail_if_unavailable" => fail_if_unavailable?,
          "because" => because,
          "legal_basis_reference" => legal_basis_reference,
          "data_protection_impact_assessment_reference" => data_protection_impact_assessment_reference
        }.compact
      end
    end

    NOT_RECORDED = Setting.new(record: false).freeze

    attr_reader :ip_address, :browser_user_agent, :ip_geolocation,
                :ip_geolocation_fields, :ip_geolocation_resolver_name,
                :review_configuration_on, :policy_key, :retention_class_key,
                :trusted_proxy_configuration_digest

    def initialize(policy_key:, retention_class_key: nil, ip_address: nil,
                   browser_user_agent: nil, ip_geolocation: nil,
                   ip_geolocation_fields: {}, ip_geolocation_resolver_name: nil,
                   trusted_proxy_configuration_digest: nil, review_configuration_on: nil)
      @policy_key = policy_key
      @retention_class_key = retention_class_key&.to_s
      @purpose_sources = {}
      @ip_address = normalized_setting(:ip_address, ip_address || NOT_RECORDED)
      @browser_user_agent = normalized_setting(:browser_user_agent, browser_user_agent || NOT_RECORDED)
      @ip_geolocation = normalized_setting(:ip_geolocation, ip_geolocation || NOT_RECORDED)
      @purpose_sources.freeze
      @ip_geolocation_fields = normalize_geolocation_fields(ip_geolocation_fields)
      @ip_geolocation_resolver_name = ip_geolocation_resolver_name&.to_sym
      @trusted_proxy_configuration_digest = trusted_proxy_configuration_digest&.to_s
      @review_configuration_on = review_configuration_on

      validate!
      freeze
    end

    def records_ip_address? = ip_address.record?
    def records_browser_user_agent? = browser_user_agent.record?
    def records_ip_geolocation? = ip_geolocation.record?

    def records_ip_geolocation_field?(field)
      ip_geolocation_fields.fetch(field.to_s, false)
    end

    def enabled_ip_geolocation_fields
      ip_geolocation_fields.select { |_, enabled| enabled }.keys
    end

    def records_anything? = records_ip_address? || records_browser_user_agent? || records_ip_geolocation?

    # Who wrote the purpose stored for this category: `"host"` when the policy
    # or the initializer supplied one, `"gem_default"` when Clickwrap filled in
    # its own. Deliberately kept off `to_snapshot`: the snapshot is a released
    # evidence format, and the answer is derivable from the configuration a
    # reader already has.
    def purpose_source_for(category)
      @purpose_sources[category.to_s]
    end

    def setting_for(category)
      case category.to_sym
      when :ip_address then ip_address
      when :browser_user_agent then browser_user_agent
      when :ip_geolocation then ip_geolocation
      else raise ArgumentError, "Unknown request-evidence category #{category.inspect}"
      end
    end

    # The exact field allowlist stored beside any recorded request evidence, so
    # a reader years later can tell what the server was authorized to keep —
    # not merely what happens to be present.
    def authorized_fields_manifest
      {
        "ip_address" => records_ip_address?,
        "browser_user_agent" => records_browser_user_agent?,
        "ip_geolocation" => ip_geolocation_fields.dup
      }
    end

    def to_snapshot
      {
        "ip_address" => ip_address.to_snapshot,
        "browser_user_agent" => browser_user_agent.to_snapshot,
        "ip_geolocation" => ip_geolocation.to_snapshot.merge(
          "fields" => ip_geolocation_fields,
          "resolver" => ip_geolocation_resolver_name&.to_s
        ).compact,
        "trusted_proxy_configuration_digest" => trusted_proxy_configuration_digest,
        "review_configuration_on" => review_configuration_on&.to_s
      }.compact
    end

    private

    def normalize_geolocation_fields(declaration)
      Vocabulary::IP_GEOLOCATION_DATA_FIELDS.to_h do |field|
        [field, declaration.transform_keys(&:to_s).fetch(field, false) == true]
      end.freeze
    end

    def validate!
      FIELD_CATEGORIES.each { |category| validate_category!(category) }
      validate_geolocation_coherence!
      validate_named_resolver!
    end

    def normalized_setting(category, setting)
      return setting unless setting.record?

      configured = case category
                   when :ip_address then Clickwrap.config.encrypt_recorded_ip_addresses
                   when :browser_user_agent then Clickwrap.config.encrypt_recorded_browser_user_agents
                   else Clickwrap.config.encrypt_recorded_ip_geolocation
                   end

      if !setting.encrypted.nil? && setting.encrypted != configured
        raise DefinitionError,
              "Policy #{policy_key} says `encrypted: #{setting.encrypted}` for #{category}, but " \
              "the application-wide storage setting is #{configured}. Active Record encryption " \
              "is configured per column, not per row, so Clickwrap refuses to record a policy " \
              "snapshot that would misdescribe storage. Change the matching " \
              "`config.encrypt_recorded_*` setting, or omit `encrypted:` to inherit it."
      end

      # The compiled revision always carries a purpose, so a reader years from
      # now never finds a recorded field with nothing beside it saying what it
      # was for. Whose sentence it is gets remembered separately.
      @purpose_sources[category.to_s] = setting.because.presence ? "host" : "gem_default"

      Setting.new(
        **setting.to_h,
        encrypted: configured,
        because: setting.because.presence || Vocabulary::DEFAULT_REQUEST_EVIDENCE_PURPOSE
      )
    end

    def validate_named_resolver!
      return unless records_ip_geolocation?

      resolver = Clickwrap.config.ip_geolocation_resolver_for(ip_geolocation_resolver_name)
      unless resolver
        raise DefinitionError,
              "Policy #{policy_key} records IP geolocation using resolver " \
              "#{ip_geolocation_resolver_name.inspect}, but no resolver is registered under " \
              "that name. Bundle `trackdown` (>= 0.4) and Clickwrap uses it for " \
              "`:application_default` with no wiring line at all, or set " \
              "`config.ip_geolocation_resolver` yourself, or register the named resolver with " \
              "`config.register_ip_geolocation_resolver`. Registered resolvers: " \
              "#{Clickwrap.config.ip_geolocation_resolver_names.join(", ").presence || "(none)"}."
      end

      capabilities = Array(resolver.capabilities).map(&:to_s)
      impossible = enabled_ip_geolocation_fields - capabilities
      return if impossible.empty?

      raise DefinitionError,
            "Policy #{policy_key} asks IP-geolocation resolver " \
            "#{ip_geolocation_resolver_name.inspect} for #{impossible.join(", ")}, but that " \
            "resolver says it cannot supply #{impossible.many? ? "those fields" : "that field"}. " \
            "Choose fields the resolver supports or configure a resolver whose `capabilities` " \
            "include them."
    rescue NotImplementedError => error
      raise DefinitionError,
            "The IP-geolocation resolver for policy #{policy_key} cannot describe its " \
            "capabilities: #{error.message}"
    end

    # A missing purpose and a missing disposal answer both have defaults now.
    # What is left refuses only the two things a default cannot honestly stand
    # in for: scaffolding text the host actually wrote, and a deletion clock
    # that is not a period.
    def validate_category!(category)
      setting = setting_for(category)
      return unless setting.record?

      if ReviewedText.placeholder?(setting.because)
        raise DefinitionError,
              "Policy #{policy_key} records #{category}, but its `because:` is still " \
              "scaffolding text (#{setting.because.inspect}). Replace it with the " \
              "application's reviewed, present-tense reason, or drop the option and let " \
              "Clickwrap record its own stated purpose; a TODO is never a data-collection " \
              "purpose."
      end

      # The legal-basis reference goes into the compiled policy revision and
      # every receipt built from it, permanently. Scaffolding there is worse
      # than an omission: an omission reads as "the host said nothing", while
      # "TODO: ask legal" reads as a reviewed determination to anyone who finds
      # it later. Same rule as `because:` — the option is optional, but text
      # the host actually wrote has to be text they meant.
      if ReviewedText.placeholder?(setting.legal_basis_reference)
        raise DefinitionError,
              "Policy #{policy_key} records #{category} with a `legal_basis_reference:` " \
              "that is still scaffolding text (#{setting.legal_basis_reference.inspect}). " \
              "Replace it with the application's own reference, or drop the option — " \
              "Clickwrap would rather record nothing than record a TODO as a legal basis."
      end

      return unless setting.delete_after && setting.delete_after.to_i <= 0

      raise DefinitionError,
            "Policy #{policy_key} sets `delete_after:` for #{category} to " \
            "#{setting.delete_after.inspect}, which is not a period in the future."
    end

    def validate_geolocation_coherence!
      enabled = enabled_ip_geolocation_fields

      if ip_geolocation.record? && enabled.empty?
        raise DefinitionError,
              "Policy #{policy_key} calls `record_ip_geolocation` and then turns every field " \
              "off, which cannot mean anything. Name the fields you want, for example " \
              "`country: true`; call `record_ip_geolocation` with no fields at all for the " \
              "coarse country, region, and city; or say `do_not_record_ip_geolocation` if that " \
              "is what you meant."
      end

      if ip_geolocation.record? &&
         records_ip_geolocation_field?(:latitude_and_longitude) &&
         !records_ip_geolocation_field?(:accuracy_radius_in_kilometers)
        raise DefinitionError,
              "Policy #{policy_key} records IP-geolocation latitude and longitude but does not " \
              "record `accuracy_radius_in_kilometers:`. Provider-derived coordinates without " \
              "their uncertainty look more precise than they are. Set both fields to true, or " \
              "turn latitude and longitude off. Clickwrap will not enable another field silently."
      end

      return if ip_geolocation.record? || enabled.empty?

      raise DefinitionError,
            "Policy #{policy_key} enables the IP-geolocation fields #{enabled.join(", ")} " \
            "without recording IP geolocation."
    end
  end
end
