# frozen_string_literal: true

module Clickwrap
  module Integrations
    # Optional adapter for https://github.com/rameerez/organizations.
    #
    # There is deliberately no runtime dependency on that gem. The adapter is
    # selected only by a policy that says
    # `permit_acting_for_organization`, and it talks to the public Membership
    # association/API when capture occurs. A missing gem, wrong represented
    # party type, missing membership, stale/insufficient role, or insufficient
    # permission all deny authority.
    class OrganizationsAuthority
      SOURCE = "organizations.membership"
      ADAPTER_VERSION = "1"

      def verify(actor:, represented_party:, authority_rule:, tenant:,
                 authentication_context:)
        return denied unless organizations_available?
        return denied unless represented_party.is_a?(::Organizations::Organization)
        return denied if represented_party.respond_to?(:persisted?) && !represented_party.persisted?
        return denied unless actor.respond_to?(:id) && actor.id.present?
        return denied if actor.respond_to?(:persisted?) && !actor.persisted?
        return denied unless represented_party.respond_to?(:memberships)
        return denied if tenant.present? && Reference.tenant(tenant) != Reference.tenant(represented_party)

        # Capture calls authority adapters inside its transaction. Taking the
        # membership row lock makes a concurrent removal or demotion serialize
        # with the evidence write instead of authorizing from a stale role.
        membership = represented_party.memberships.lock.find_by(user_id: actor.id)
        return denied unless membership
        return denied unless sufficient_role?(membership, authority_rule.minimum_role)
        return denied unless sufficient_permission?(membership, authority_rule.required_permission)

        AuthorityDecision.new(
          authorized: true,
          source: SOURCE,
          role: membership_role(membership),
          verified_at: Clickwrap.now,
          details: {
            "adapter_version" => ADAPTER_VERSION,
            "membership_reference" => Reference.record(membership),
            "represented_party_reference" => Reference.record(represented_party),
            "minimum_role" => authority_rule.minimum_role,
            "required_permission" => authority_rule.required_permission,
            "required_permission_was_granted" => authority_rule.required_permission.present? || nil,
            "authentication_method" => authentication_context.to_h[:method]&.to_s
          }.compact
        )
      rescue NoMethodError
        denied
      end

      private

      def organizations_available?
        defined?(::Organizations::Membership) && defined?(::Organizations::Roles)
      end

      def membership_role(membership)
        membership.respond_to?(:role_sym) ? membership.role_sym.to_s : membership.role.to_s
      end

      def sufficient_role?(membership, minimum_role)
        return true if minimum_role.blank?

        membership.respond_to?(:is_at_least?) && membership.is_at_least?(minimum_role)
      end

      def sufficient_permission?(membership, required_permission)
        return true if required_permission.blank?

        membership.respond_to?(:has_permission_to?) && membership.has_permission_to?(required_permission)
      end

      def denied
        AuthorityDecision.new(authorized: false, source: SOURCE)
      end
    end
  end
end
