# frozen_string_literal: true

module Clickwrap
  module DSL
    # The block passed to `Clickwrap.policy`.
    #
    #   Clickwrap.policy :signup do
    #     agree_to :terms
    #     acknowledge :privacy_notice
    #     retain_with :ordinary_agreement_evidence
    #   end
    #
    # The verbs are deliberate. `agree_to :terms` and `consent_to :marketing`
    # are different sentences because they are different acts with different
    # lifecycles, and a developer choosing between them is doing the one piece
    # of thinking this gem cannot do for them.
    class PolicyBuilder
      STATEMENT_OPTIONS = %i[
        document
        statement
        label
        link_label
        choices
        purpose
        withdrawal_path
        valid_for
        requires
        subject_fingerprint_with
        subject_fingerprint_version
        record_protected_outcome_with
        protected_outcome_version
        optional
        require_an_explicit_choice
        one_time
        require_current_version
      ].freeze
      DEFAULT_RETENTION_SETTING_NAMES = {
        ip_address: :delete_recorded_ip_addresses_after,
        browser_user_agent: :delete_recorded_browser_user_agents_after,
        ip_geolocation: :delete_recorded_ip_geolocation_after
      }.freeze

      def initialize(key)
        @key = key.to_s
        @statements = []
        @retention_class_key = nil
        @request_evidence = {}
        @ip_geolocation_fields = {}
        @persist_presentations_for = nil
        @persist_presentations_because = nil
        @capture_channels = nil
        @locales = nil
        @tenant_scope = "optional"
        @options = {}
        @authority_rule = nil
        @ip_geolocation_resolver_name = nil
        @review_request_evidence_configuration_on = nil
      end

      # --- The six verbs --------------------------------------------------------

      # Assent to contractual terms.
      def agree_to(statement_key, **options)
        add_statement(statement_key, "agreement", options)
      end

      # Affirmative receipt or awareness of a notice or risk. This is not
      # permission, and it is not consent: a privacy notice is information the
      # person is entitled to, not something they agree to.
      def acknowledge(statement_key, **options)
        add_statement(statement_key, "acknowledgment", options)
      end

      # Purpose-specific permission, where the host has decided consent is the
      # right basis for this processing. Clickwrap does not make that decision;
      # it makes the grant, the withdrawal, and the scope demonstrable.
      def consent_to(statement_key, **options)
        add_statement(statement_key, "consent", options)
      end

      # A factual statement made by the actor. A declaration can expire without
      # implying it was false when it was made.
      def declare(statement_key, **options)
        add_statement(statement_key, "declaration", options)
      end

      # An operational fact affirmed by an authorized actor, usually an
      # operator rather than an end user.
      def attest(statement_key, **options)
        add_statement(statement_key, "attestation", options)
      end

      # Narrow permission bound to one protected action. This is the difference
      # between "the user once accepted something" and "this exact evidence
      # authorized this exact operation".
      def authorize(statement_key, **options)
        add_statement(statement_key, "authorization", options)
      end

      # --- Policy-level settings ------------------------------------------------

      def retain_with(retention_class_key)
        @retention_class_key = retention_class_key.to_s
      end

      # Keep the presentation manifest for renders that were never submitted.
      # The default path writes nothing on GET; this trades that for a record
      # of display attempts, which some high-assurance flows want. An abandoned
      # GET is labeled `presented_by_server` — never `accepted`, and never
      # `seen_by_human`.
      def persist_presentations_before_submission_for(duration, because: nil, **unknown_options)
        refuse_unknown_options!("persist_presentations_before_submission_for", unknown_options)
        @persist_presentations_for = duration
        @persist_presentations_because = because
      end

      # Restrict which capture channels this policy accepts. By default all are
      # allowed and the channel is recorded; a policy that should only ever be
      # completed in a browser can say so.
      def only_capture_from(*channels)
        @capture_channels = channels.flatten.map(&:to_s)
      end

      # Restrict the policy to locales it can actually present. A required
      # legal statement should not fall back to a language nobody chose.
      def only_present_in(*locales)
        @locales = locales.flatten.map(&:to_s)
      end

      # Declares whether this policy is personal, tenant-bound, or deliberately
      # usable in either context. The same policy-level decision is applied to
      # presentation, capture, and verification, so ambient organization state
      # cannot appear on only one side of a signed submission.
      #
      #   tenant_is :not_applicable # personal evidence; ignore ambient tenant
      #   tenant_is :required       # every call must resolve a tenant
      #   tenant_is :optional       # either context is deliberate (the default)
      def tenant_is(scope)
        @tenant_scope = scope.to_s
      end

      # Allow explicitly recorded system exemptions for this policy. Even when
      # allowed, an exemption never answers `agreed_to?` — it answers
      # `exempted_from?`. There is no "missing checkbox means system account"
      # inference anywhere in this gem.
      def permit_exemptions(because: nil, **unknown_options)
        refuse_unknown_options!("permit_exemptions", unknown_options)
        @options[:permit_exemptions] = true
        @options[:permit_exemptions_because] = because
      end

      # Allow an actor to act for a represented party (an employee signing for
      # an organization, a guardian, a service account). The receipt keeps the
      # authenticated principal, the asserted actor, and the represented party
      # as three separate facts. Clickwrap does not decide whether the
      # authority is sufficient.
      def permit_acting_for(*represented_party_types, using: :host,
                            when_actor_is_at_least: nil, when_actor_has_permission: nil,
                            **unknown_options)
        refuse_unknown_options!("permit_acting_for", unknown_options)
        if represented_party_types.compact.all? { |type| type.to_s.strip.empty? }
          raise DefinitionError,
                "permit_acting_for needs at least one represented-party class name. " \
                "Name every type this policy permits so it cannot authorize an unexpected kind of record."
        end

        @options[:permit_acting_for] = true
        @authority_rule = AuthorityRule.new(
          represented_party_types: represented_party_types,
          adapter_name: using,
          minimum_role: when_actor_is_at_least,
          required_permission: when_actor_has_permission
        )
      end

      # One-line integration with https://github.com/rameerez/organizations.
      # The User remains the human actor; Organizations::Organization is the
      # represented party. A policy must name at least one reviewed authority
      # criterion rather than silently treating every member as able to bind it.
      #
      #   permit_acting_for_organization when_actor_is_at_least: :admin
      #
      def permit_acting_for_organization(when_actor_is_at_least: nil,
                                         when_actor_has_permission: nil,
                                         **unknown_options)
        refuse_unknown_options!("permit_acting_for_organization", unknown_options)
        if when_actor_is_at_least.nil? && when_actor_has_permission.nil?
          raise DefinitionError,
                "permit_acting_for_organization needs `when_actor_is_at_least:` or " \
                "`when_actor_has_permission:`. Organization membership alone does not establish " \
                "legal authority to bind the organization."
        end

        permit_acting_for(
          "Organizations::Organization",
          using: :organizations_membership,
          when_actor_is_at_least:,
          when_actor_has_permission:
        )
      end

      # --- Request evidence -----------------------------------------------------

      def record_ip_address(encrypted: nil, delete_after: nil, retain_until: nil,
                            fail_if_unavailable: false, because: nil, legal_basis_reference: nil,
                            **unknown_options)
        refuse_unknown_options!("record_ip_address", unknown_options)
        @request_evidence[:ip_address] = RequestEvidencePolicy::Setting.new(
          record: true, encrypted:, delete_after:, retain_until:, fail_if_unavailable:,
          because:, legal_basis_reference:
        )
      end

      # A policy-level refusal wins over an application-wide default. This is a
      # named method rather than `record: false`: a privacy-reducing decision
      # should read unambiguously in review and must not be confused with an
      # omitted option.
      def do_not_record_ip_address
        @request_evidence[:ip_address] = RequestEvidencePolicy::NOT_RECORDED
      end

      def record_browser_user_agent(encrypted: nil, delete_after: nil, retain_until: nil,
                                    fail_if_unavailable: false, because: nil,
                                    legal_basis_reference: nil, **unknown_options)
        refuse_unknown_options!("record_browser_user_agent", unknown_options)
        @request_evidence[:browser_user_agent] = RequestEvidencePolicy::Setting.new(
          record: true, encrypted:, delete_after:, retain_until:, fail_if_unavailable:,
          because:, legal_basis_reference:
        )
      end

      def do_not_record_browser_user_agent
        @request_evidence[:browser_user_agent] = RequestEvidencePolicy::NOT_RECORDED
      end

      # Each IP-geolocation data field is named separately, because each one is
      # a separate decision about what to keep about a person's network
      # context. `latitude_and_longitude` is one coupled choice: half a
      # coordinate is not a result. Whatever is enabled, the provider name,
      # source, estimated status, resolution time, and any accuracy or database
      # provenance the resolver supplies are stored with it automatically — a
      # policy cannot keep the coordinates and drop the uncertainty needed to
      # read them.
      def record_ip_geolocation(country: false, region: false, city: false, postal_code: false,
                                latitude_and_longitude: false, timezone: false, continent: false,
                                metro_code: false, accuracy_radius_in_kilometers: false,
                                using: nil, encrypted: nil, delete_after: nil, retain_until: nil,
                                fail_if_unavailable: false, because: nil,
                                legal_basis_reference: nil,
                                data_protection_impact_assessment_reference: nil,
                                **unknown_options)
        refuse_unknown_options!("record_ip_geolocation", unknown_options)
        @ip_geolocation_fields = {
          "country" => country,
          "region" => region,
          "city" => city,
          "postal_code" => postal_code,
          "latitude_and_longitude" => latitude_and_longitude,
          "timezone" => timezone,
          "continent" => continent,
          "metro_code" => metro_code,
          "accuracy_radius_in_kilometers" => accuracy_radius_in_kilometers
        }
        @ip_geolocation_resolver_name = using

        @request_evidence[:ip_geolocation] = RequestEvidencePolicy::Setting.new(
          record: true, encrypted:, delete_after:, retain_until:, fail_if_unavailable:,
          because:, legal_basis_reference:, data_protection_impact_assessment_reference:
        )
      end

      def do_not_record_ip_geolocation
        @request_evidence[:ip_geolocation] = RequestEvidencePolicy::NOT_RECORDED
        @ip_geolocation_fields = {}
        @ip_geolocation_resolver_name = nil
      end

      # A date by which someone should look at this policy's request-evidence
      # configuration again. `clickwrap:doctor` reports policies that collect
      # personal data without one, and policies whose date has passed.
      def review_request_evidence_configuration_on(date)
        @review_request_evidence_configuration_on = date
      end

      # --- Compilation ----------------------------------------------------------

      def compile
        Policy.new(
          key: @key,
          statements: @statements,
          retention_class_key: @retention_class_key,
          request_evidence: build_request_evidence_policy,
          persist_presentations_for: @persist_presentations_for,
          persist_presentations_because: @persist_presentations_because,
          capture_channels: @capture_channels,
          locales: @locales,
          tenant_scope: @tenant_scope,
          authority_rule: @authority_rule,
          options: @options
        )
      end

      private

      def add_statement(statement_key, kind, options)
        refuse_unknown_statement_options!(statement_key, options)
        @statements << Statement.new(
          key: statement_key,
          kind: kind,
          ordinal: @statements.length,
          options: default_statement_options(statement_key, kind).merge(options)
        )
      end

      # A statement's document defaults to a document with the same key, and
      # its assertion defaults to a conventional I18n key. Both are overridable;
      # the defaults exist so the five-minute path needs no boilerplate, not so
      # that anything is guessed silently — a missing document or translation
      # still fails loudly.
      def default_statement_options(statement_key, kind)
        {
          document: statement_key,
          statement: :"clickwrap.statements.#{kind}.#{statement_key}"
        }
      end

      def build_request_evidence_policy
        ip_address = resolved_request_evidence_setting(:ip_address)
        browser_user_agent = resolved_request_evidence_setting(:browser_user_agent)
        ip_geolocation = resolved_request_evidence_setting(:ip_geolocation)
        geolocation_fields = resolved_ip_geolocation_fields(ip_geolocation)

        RequestEvidencePolicy.new(
          policy_key: @key,
          retention_class_key: @retention_class_key,
          ip_address:,
          browser_user_agent:,
          ip_geolocation:,
          ip_geolocation_fields: geolocation_fields,
          ip_geolocation_resolver_name: resolved_ip_geolocation_resolver_name(ip_geolocation),
          trusted_proxy_configuration_digest: resolved_trusted_proxy_configuration_digest(
            ip_address:, ip_geolocation:
          ),
          review_configuration_on: @review_request_evidence_configuration_on ||
            Clickwrap.config.review_default_request_evidence_configuration_on
        )
      end

      def resolved_request_evidence_setting(category)
        return @request_evidence.fetch(category) if @request_evidence.key?(category)

        application_default_setting(category)
      end

      def application_default_setting(category)
        enabled = case category
                  when :ip_address then Clickwrap.config.record_ip_address_by_default
                  when :browser_user_agent then Clickwrap.config.record_browser_user_agent_by_default
                  else Clickwrap.config.enabled_default_ip_geolocation_fields.any?
                  end
        return RequestEvidencePolicy::NOT_RECORDED unless enabled

        RequestEvidencePolicy::Setting.new(
          record: true,
          encrypted: application_default_encryption(category),
          delete_after: Clickwrap.config.public_send(
            DEFAULT_RETENTION_SETTING_NAMES.fetch(category)
          ),
          fail_if_unavailable: category == :ip_geolocation &&
            Clickwrap.config.fail_capture_when_ip_geolocation_is_unavailable,
          because: application_default_reason(category),
          legal_basis_reference: application_default_legal_basis_reference(category)
        )
      end

      def application_default_encryption(category)
        case category
        when :ip_address then Clickwrap.config.encrypt_recorded_ip_addresses
        when :browser_user_agent then Clickwrap.config.encrypt_recorded_browser_user_agents
        else Clickwrap.config.encrypt_recorded_ip_geolocation
        end
      end

      def application_default_reason(category)
        case category
        when :ip_address then Clickwrap.config.reason_for_recording_ip_addresses_by_default
        when :browser_user_agent then Clickwrap.config.reason_for_recording_browser_user_agents_by_default
        else Clickwrap.config.reason_for_recording_ip_geolocation_by_default
        end
      end

      def application_default_legal_basis_reference(category)
        case category
        when :ip_address then Clickwrap.config.legal_basis_reference_for_recording_ip_addresses_by_default
        when :browser_user_agent
          Clickwrap.config.legal_basis_reference_for_recording_browser_user_agents_by_default
        else Clickwrap.config.legal_basis_reference_for_recording_ip_geolocation_by_default
        end
      end

      def resolved_ip_geolocation_fields(setting)
        return {} unless setting.record?
        return @ip_geolocation_fields if @request_evidence.key?(:ip_geolocation)

        Vocabulary::IP_GEOLOCATION_DATA_FIELDS.to_h do |field|
          [field, Clickwrap.config.public_send(:"record_ip_geolocation_#{field}_by_default")]
        end
      end

      def resolved_ip_geolocation_resolver_name(setting)
        return nil unless setting.record?

        @ip_geolocation_resolver_name || :application_default
      end

      def resolved_trusted_proxy_configuration_digest(ip_address:, ip_geolocation:)
        return nil unless ip_address.record? || ip_geolocation.record?

        Clickwrap.config.trusted_proxy_configuration_digest
      end

      def refuse_unknown_statement_options!(statement_key, options)
        unknown = options.keys.map(&:to_sym) - STATEMENT_OPTIONS
        return if unknown.empty?

        aliases = {
          documents: :document,
          assertion: :statement,
          link_labels: :link_label
        }
        replacements = unknown.filter_map do |option|
          "`#{option}:` was renamed to `#{aliases.fetch(option)}:`" if aliases.key?(option)
        end
        correction = replacements.empty? ? "" : " #{replacements.join("; ")}."

        raise DefinitionError,
              "Statement #{statement_key} in policy #{@key} has unknown option#{"s" if unknown.many?} " \
              "#{unknown.map { |option| "`#{option}:`" }.join(", ")}.#{correction} " \
              "Supported options are: #{STATEMENT_OPTIONS.map { |option| "`#{option}:`" }.join(", ")}. " \
              "Clickwrap never ignores policy options."
      end

      def refuse_unknown_options!(method_name, options)
        return if options.empty?

        raise DefinitionError,
              "Policy #{@key} calls `#{method_name}` with unknown option" \
              "#{"s" if options.many?} #{options.keys.map { |option| "`#{option}:`" }.join(", ")}. " \
              "Check the spelling; Clickwrap never ignores policy options."
      end

      def method_missing(name, *_arguments, **_options)
        raise DefinitionError,
              "Policy #{@key} calls unknown DSL method `#{name}`. Check the spelling; " \
              "Clickwrap never ignores policy declarations."
      end

      def respond_to_missing?(_name, _include_private = false) = false
    end
  end
end
