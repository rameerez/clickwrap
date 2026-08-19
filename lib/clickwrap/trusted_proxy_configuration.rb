# frozen_string_literal: true

require "ipaddr"

module Clickwrap
  # Produces a stable digest from the effective trusted-proxy rules themselves.
  # A sentence such as "Cloudflare proxies" is not configuration evidence; the
  # normalized address ranges and regular expressions are.
  module TrustedProxyConfiguration
    SCHEMA = "clickwrap.trusted-proxy-configuration.v1"

    class << self
      def digest_for(trusted_proxies, source: "host_configuration")
        entries = collection(trusted_proxies).map { |entry| normalize(entry) }
        entries.sort_by! { |entry| CanonicalJson.generate(entry) }

        payload = {
          "schema" => SCHEMA,
          "source" => source.to_s,
          "entries" => entries
        }
        Digest.digest_canonical(payload)
      end

      def digest_for_rails_application(application)
        configured = application.config.action_dispatch.trusted_proxies
        if configured.nil?
          require "action_dispatch/middleware/remote_ip"
          configured = ActionDispatch::RemoteIp::TRUSTED_PROXIES
          source = "rails_default_trusted_proxies"
        else
          source = "rails_application_config_action_dispatch_trusted_proxies"
        end

        digest_for(configured, source: source)
      end

      private

      def collection(value)
        return value.to_a if value.is_a?(Array) || value.is_a?(Set)
        return [value] if proxy_entry?(value)
        return value.to_a if value.respond_to?(:to_a) && !value.is_a?(Hash)

        raise ConfigurationError,
              "Trusted proxy configuration must be a proxy rule or a collection of proxy rules; " \
              "got #{value.class}. Pass the same IP ranges or regular expressions Rails uses."
      end

      def proxy_entry?(value)
        value.is_a?(IPAddr) || value.is_a?(Regexp) || value.is_a?(Range) ||
          value.is_a?(String) || value.is_a?(Symbol) || value.is_a?(Hash)
      end

      def normalize(value)
        case value
        when IPAddr
          range = value.to_range
          { "type" => "ip_address_range", "first" => range.begin.to_s, "last" => range.end.to_s }
        when Regexp
          { "type" => "regular_expression", "source" => value.source, "options" => value.options }
        when Range
          {
            "type" => "range",
            "first" => value.begin.to_s,
            "last" => value.end.to_s,
            "excludes_last" => value.exclude_end?
          }
        when String, Symbol
          { "type" => "literal", "value" => value.to_s }
        when Hash
          normalize_hash(value)
        else
          raise ConfigurationError,
                "Trusted proxy rule #{value.inspect} (#{value.class}) cannot be serialized " \
                "deterministically. Use explicit IPAddr ranges, regular expressions, ranges, " \
                "strings, or a canonical Hash describing the effective rule."
        end
      end

      def normalize_hash(value)
        normalized = value.deep_stringify_keys
        CanonicalJson.generate(normalized)
        { "type" => "configuration", "value" => normalized }
      rescue CanonicalJson::SerializationError => error
        raise ConfigurationError,
              "Trusted proxy configuration contains a value that cannot be canonicalized: " \
              "#{error.message}"
      end
    end
  end
end
