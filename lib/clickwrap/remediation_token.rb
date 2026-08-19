# frozen_string_literal: true

module Clickwrap
  # A short-lived, signed handoff from a host gate to the standalone capture
  # screen. It binds the exact actor, tenant, policy, subject, represented party,
  # subject fingerprint, and local return path. The browser transports this
  # context; it never chooses it.
  class RemediationToken
    PURPOSE = "clickwrap/remediation"
    SCHEMA = "clickwrap.remediation.v1"

    Context = Data.define(:policy, :actor_reference, :tenant_reference, :subject,
                          :represented_party, :return_to, :attributes)

    class << self
      def issue(policy:, actor:, tenant: nil, subject: nil, represented_party: nil,
                return_to: nil, issued_at: nil)
        issued_at ||= Clickwrap.now
        expires_at = issued_at + Clickwrap.config.remediation_token_valid_for

        attributes = {
          "schema" => SCHEMA,
          "policy" => policy.key,
          "actor_reference" => Reference.actor(actor),
          "tenant_reference" => Reference.tenant(tenant),
          "subject" => record_binding(subject, "subject", expires_at: expires_at),
          "subject_fingerprint" => SubjectFingerprint.for(policy, subject),
          "represented_party" => record_binding(
            represented_party, "represented_party", expires_at: expires_at
          ),
          "return_to" => return_to,
          "issued_at" => Receipt.format_time(issued_at),
          "expires_at" => Receipt.format_time(expires_at),
          "nonce" => SecureRandom.uuid
        }.compact

        verifier.generate(attributes, purpose: PURPOSE, expires_at: expires_at)
      end

      def resolve!(token, policy:, actor:)
        attributes = verifier.verified(token.to_s, purpose: PURPOSE)
        raise RemediationInvalid, "The remediation token is missing, expired, or invalid." unless attributes

        unless attributes["schema"] == SCHEMA && attributes["policy"] == policy.key
          raise RemediationInvalid, "The remediation token belongs to a different policy."
        end

        unless secure_equal?(attributes["actor_reference"], Reference.actor(actor))
          raise RemediationInvalid, "The remediation token belongs to a different actor."
        end

        # The tenant is CARRIED, not compared: the gate resolved it server-side
        # and signed it, and the engine's own routes have no ambient tenant to
        # compare against — a comparison here permanently 404'd every
        # remediation issued from a tenant-scoped page. The signature is the
        # authority; the resolved context hands the tenant back to
        # presentation and capture exactly like the subject.

        subject = resolve_record(attributes["subject"], "subject")
        represented_party = resolve_record(attributes["represented_party"], "represented_party")
        expected_fingerprint = SubjectFingerprint.for(policy, subject)

        unless secure_equal?(attributes["subject_fingerprint"], expected_fingerprint)
          raise RemediationInvalid,
                "The remediation subject changed after this route was issued. Return to the " \
                "blocked action and start again against its current state."
        end

        Context.new(
          policy: policy,
          actor_reference: attributes["actor_reference"],
          tenant_reference: attributes["tenant_reference"],
          subject: subject,
          represented_party: represented_party,
          return_to: attributes["return_to"],
          attributes: attributes.freeze
        )
      rescue ActiveSupport::MessageVerifier::InvalidSignature
        raise RemediationInvalid, "The remediation token is missing, expired, or invalid."
      end

      def reset_verifier! = @verifier = nil

      private

      def record_binding(record, name, expires_at:)
        return nil if record.nil?

        display_name = name.tr("_", " ")

        unless record.respond_to?(:to_sgid)
          raise DefinitionError,
                "A remediation #{display_name} must support Signed Global ID (`to_sgid`) so the capture " \
                "screen can resolve the exact server-owned record without trusting browser parameters."
        end

        {
          "reference" => Reference.record(record),
          "type" => record.class.name,
          "signed_global_id" => record.to_sgid(
            expires_at: expires_at,
            for: "#{PURPOSE}/#{name}"
          ).to_s
        }
      end

      def resolve_record(binding, name)
        return nil if binding.nil?

        display_name = name.tr("_", " ")
        raise RemediationInvalid, "The remediation #{display_name} binding is malformed." unless binding.is_a?(Hash)

        record = if defined?(::GlobalID::Locator)
                   ::GlobalID::Locator.locate_signed(
                     binding["signed_global_id"], for: "#{PURPOSE}/#{name}"
                   )
                 end

        unless record && binding["type"] == record.class.name &&
               secure_equal?(binding["reference"], Reference.record(record))
          raise RemediationInvalid,
                "The remediation #{display_name} no longer exists or no longer matches the signed route."
        end

        record
      rescue ActiveRecord::RecordNotFound
        raise RemediationInvalid,
              "The remediation #{name.tr("_", " ")} no longer exists or no longer matches the signed route."
      end

      def secure_equal?(left, right)
        Digest.secure_compare?(left.to_s, right.to_s)
      end

      def verifier
        @verifier ||= ActiveSupport::MessageVerifier.new(
          signing_secret,
          digest: "SHA256",
          serializer: JSON
        )
      end

      def signing_secret
        if defined?(::Rails) && ::Rails.application&.key_generator
          ::Rails.application.key_generator.generate_key("clickwrap/remediation-token", 32)
        else
          ENV.fetch("CLICKWRAP_REMEDIATION_SECRET") do
            raise ConfigurationError,
                  "Clickwrap needs CLICKWRAP_REMEDIATION_SECRET outside Rails to sign remediation routes."
          end
        end
      end
    end
  end
end
