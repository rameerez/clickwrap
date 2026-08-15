# frozen_string_literal: true

module Clickwrap
  # What one policy is allowed to record about the HTTP request that carried a
  # capture.
  #
  # Everything here is off unless a policy or the initializer names it. That is
  # not squeamishness about useful data: it is that high-quality evidence is
  # purpose-specific. An IP address is personal data, and keeping it on your own
  # infrastructure does not remove the duty to have a reason for it, protect it,
  # and stop keeping it eventually. So each field is enabled by name, with a
  # plain-English purpose and a retention decision attached, and the policy that
  # enables it is the server's, never the browser's.
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
      def initialize(record: false, encrypted: true, delete_after: nil, retain_until: nil,
                     fail_if_unavailable: false, because: nil, legal_basis_reference: nil,
                     data_protection_impact_assessment_reference: nil)
        super
      end

      def record? = record == true
      def encrypted? = encrypted != false
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
                :review_configuration_on, :policy_key

    def initialize(policy_key:, ip_address: nil, browser_user_agent: nil, ip_geolocation: nil,
                   ip_geolocation_fields: {}, ip_geolocation_resolver_name: nil,
                   review_configuration_on: nil)
      @policy_key = policy_key
      @ip_address = ip_address || NOT_RECORDED
      @browser_user_agent = browser_user_agent || NOT_RECORDED
      @ip_geolocation = ip_geolocation || NOT_RECORDED
      @ip_geolocation_fields = normalize_geolocation_fields(ip_geolocation_fields)
      @ip_geolocation_resolver_name = ip_geolocation_resolver_name&.to_sym
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
    end

    def validate_category!(category)
      setting = setting_for(category)
      return unless setting.record?

      if setting.because.to_s.strip.empty?
        raise DefinitionError,
              "Policy #{policy_key} records #{category} but gives no `because:`. Say in one " \
              "plain sentence why this policy needs it right now. \"We might need it someday\" " \
              "is not a purpose, and a privacy notice mentioning the field is not one either."
      end

      if setting.delete_after.nil? && setting.retain_until.nil?
        raise DefinitionError,
              "Policy #{policy_key} records #{category} but never says when to delete it. " \
              "Give it `delete_after:` with a duration, or `retain_until:` naming a host event " \
              "rule. Clickwrap has no keep-forever default."
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
              "Policy #{policy_key} calls `record_ip_geolocation` but enables no field. " \
              "Name the fields you actually need, for example `country: true`."
      end

      return if ip_geolocation.record? || enabled.empty?

      raise DefinitionError,
            "Policy #{policy_key} enables the IP-geolocation fields #{enabled.join(', ')} " \
            "without recording IP geolocation."
    end
  end
end
