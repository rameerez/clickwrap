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
        @options = {}
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
      def persist_presentations_before_submission_for(duration, because: nil)
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

      # Allow explicitly recorded system exemptions for this policy. Even when
      # allowed, an exemption never answers `agreed_to?` — it answers
      # `exempted_from?`. There is no "missing checkbox means system account"
      # inference anywhere in this gem.
      def permit_exemptions(because: nil)
        @options[:permit_exemptions] = true
        @options[:permit_exemptions_because] = because
      end

      # Allow an actor to act for a represented party (an employee signing for
      # an organization, a guardian, a service account). The receipt keeps the
      # authenticated principal, the asserted actor, and the represented party
      # as three separate facts. Clickwrap does not decide whether the
      # authority is sufficient.
      def permit_acting_for
        @options[:permit_acting_for] = true
      end

      # --- Request evidence -----------------------------------------------------

      def record_ip_address(encrypted: true, delete_after: nil, retain_until: nil,
                            fail_if_unavailable: false, because: nil, legal_basis_reference: nil)
        @request_evidence[:ip_address] = RequestEvidencePolicy::Setting.new(
          record: true, encrypted:, delete_after:, retain_until:, fail_if_unavailable:,
          because:, legal_basis_reference:
        )
      end

      def record_browser_user_agent(encrypted: true, delete_after: nil, retain_until: nil,
                                    fail_if_unavailable: false, because: nil,
                                    legal_basis_reference: nil)
        @request_evidence[:browser_user_agent] = RequestEvidencePolicy::Setting.new(
          record: true, encrypted:, delete_after:, retain_until:, fail_if_unavailable:,
          because:, legal_basis_reference:
        )
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
                                using: nil, encrypted: true, delete_after: nil, retain_until: nil,
                                fail_if_unavailable: false, because: nil,
                                legal_basis_reference: nil,
                                data_protection_impact_assessment_reference: nil)
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
          options: @options
        )
      end

      private

      def add_statement(statement_key, kind, options)
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
        RequestEvidencePolicy.new(
          policy_key: @key,
          ip_address: @request_evidence[:ip_address],
          browser_user_agent: @request_evidence[:browser_user_agent],
          ip_geolocation: @request_evidence[:ip_geolocation],
          ip_geolocation_fields: @ip_geolocation_fields,
          ip_geolocation_resolver_name: @ip_geolocation_resolver_name,
          review_configuration_on: @review_request_evidence_configuration_on
        )
      end
    end
  end
end
