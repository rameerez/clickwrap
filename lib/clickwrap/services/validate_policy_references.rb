# frozen_string_literal: true

require "uri"

module Clickwrap
  module Services
    # The policy DSL compiles each declaration immediately, while references may
    # legitimately point at a declaration in a later file. This second pass runs
    # after every file has loaded and resolves those names as one graph. A typo
    # therefore fails boot, never the first production capture.
    class ValidatePolicyReferences
      def self.call = new.call

      def call
        Clickwrap.policies.each do |policy|
          validate_documents!(policy)
          retention_class = validate_retention_class!(policy)
          validate_request_evidence_retention!(policy, retention_class)
          validate_host_calculations!(policy, retention_class)
          validate_authority_adapter!(policy)
          validate_ip_geolocation_resolver!(policy)
        end

        true
      end

      # Routes are not knowable while Rails is still drawing them. The engine
      # invokes this method from `after_routes_loaded`; non-Rails users still get
      # syntax validation from Statement itself.
      def self.validate_remediation_paths!
        return true unless defined?(::Rails) && ::Rails.respond_to?(:application)
        return true unless ::Rails.application

        Clickwrap.policies.each do |policy|
          policy.consent_statements.each do |statement|
            validate_remediation_path!(policy, statement)
          end
        end

        true
      end

      class << self
        private

        def validate_remediation_path!(policy, statement)
          value = statement.withdrawal_path.to_s
          uri = URI.parse(value)
          return if %w[http https].include?(uri.scheme) && uri.host.present?

          unless uri.scheme.nil? && value.start_with?("/")
            raise DefinitionError,
                  "Consent statement #{statement.key} in policy #{policy.key} has withdrawal " \
                  "path #{value.inspect}. Use an absolute application path beginning with `/`, " \
                  "or a complete `https://` URL."
          end

          ::Rails.application.routes.recognize_path(uri.path, method: :get)
        rescue URI::InvalidURIError
          raise DefinitionError,
                "Consent statement #{statement.key} in policy #{policy.key} has malformed " \
                "withdrawal path #{value.inspect}. Give it the exact page a person can visit."
        rescue ActionController::RoutingError
          raise DefinitionError,
                "Consent statement #{statement.key} in policy #{policy.key} points at " \
                "#{value.inspect}, but the host has no GET route for that path. Add the route or " \
                "correct `withdrawal_path:` so consent is not easier to give than to withdraw."
        end
      end

      private

      def validate_documents!(policy)
        policy.document_keys.each do |document_key|
          definitions = Clickwrap.documents.values.select { |definition| definition.key == document_key }
          if definitions.empty?
            raise DefinitionError,
                  "Policy #{policy.key} presents document #{document_key.inspect}, but no " \
                  "`Clickwrap.document #{document_key.to_sym.inspect}, ...` declaration exists. " \
                  "(A statement's document defaults to its own key; if this statement is about " \
                  "an operational fact with no published document — the statement text itself " \
                  "is the whole notice — say so with `document: nil`.)"
          end

          next if policy.locales.nil?

          available = definitions.map(&:locale).uniq
          missing = policy.locales - available
          next if missing.empty?

          raise DefinitionError,
                "Policy #{policy.key} can be presented in #{missing.join(", ")}, but document " \
                "#{document_key.inspect} has no declaration in #{missing.join(", ")}. Declare " \
                "one immutable version per permitted locale."
        end
      end

      def validate_retention_class!(policy)
        Clickwrap.retention_classes[policy.retention_class_key] ||
          raise(
            DefinitionError,
            "Policy #{policy.key} says `retain_with #{policy.retention_class_key.to_sym.inspect}`, " \
            "but no retention class with that key is declared. Define it with " \
            "`Clickwrap.retention #{policy.retention_class_key.to_sym.inspect} do ... end`."
          )
      end

      def validate_request_evidence_retention!(policy, retention_class)
        RequestEvidencePolicy::FIELD_CATEGORIES.each do |category|
          setting = policy.request_evidence.setting_for(category)
          next unless setting.record?
          next if setting.delete_after || setting.retain_until || retention_class.rule_for(category)

          raise DefinitionError,
                "Policy #{policy.key} records #{category}, but neither that policy nor retention " \
                "class #{retention_class.key} says when to dispose of it. Add " \
                "`delete_after:`/`retain_until:` to the policy or the matching plain-English " \
                "request-evidence rule to the retention class."
        end
      end

      def validate_host_calculations!(policy, retention_class)
        referenced = retention_class.rules.values.filter_map do |rule|
          rule.host_event_name&.to_sym
        end
        referenced.concat(
          RequestEvidencePolicy::FIELD_CATEGORIES.filter_map do |category|
            policy.request_evidence.setting_for(category).retain_until&.to_sym
          end
        )

        missing = referenced.uniq - Clickwrap.config.retention_time_calculator_names
        return if missing.empty?

        raise DefinitionError,
              "Policy #{policy.key} refers to unregistered retention calculation" \
              "#{"s" if missing.many?} #{missing.map(&:inspect).join(", ")}. Register every name " \
              "with `config.calculate_retention_time_for` so disposition never waits forever on " \
              "a typo."
      end

      def validate_authority_adapter!(policy)
        rule = policy.authority_rule
        return unless rule
        return if rule.adapter_name == "host"
        return if Clickwrap.config.represented_party_authority_adapter(rule.adapter_name)

        raise DefinitionError,
              "Policy #{policy.key} names represented-party authority adapter " \
              "#{rule.adapter_name.inspect}, but it is not registered."
      end

      def validate_ip_geolocation_resolver!(policy)
        request_evidence = policy.request_evidence
        return unless request_evidence.records_ip_geolocation?
        return if Clickwrap.config.ip_geolocation_resolver_for(
          request_evidence.ip_geolocation_resolver_name
        )

        raise DefinitionError,
              "Policy #{policy.key} names IP-geolocation resolver " \
              "#{request_evidence.ip_geolocation_resolver_name.inspect}, but it is not configured."
      end
    end
  end
end
