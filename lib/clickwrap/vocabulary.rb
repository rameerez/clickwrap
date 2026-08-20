# frozen_string_literal: true

module Clickwrap
  # Every stable string Clickwrap writes into evidence lives here, frozen, in
  # one place. Historical receipts are read by code that may be years newer
  # than the code that wrote them, so these values are part of the public
  # compatibility promise: they are added to, never renamed or repurposed.
  #
  # This taxonomy is product design. It is not a statutory vocabulary, and
  # naming an act `agreement` or `consent` does not determine its legal effect.
  module Vocabulary
    # The six kinds, each with the lifecycle it actually needs.
    KINDS = %w[
      agreement
      acknowledgment
      consent
      declaration
      attestation
      authorization
    ].freeze

    # The policy DSL verb that declares each kind.
    VERB_FOR_KIND = {
      "agreement" => "agree_to",
      "acknowledgment" => "acknowledge",
      "consent" => "consent_to",
      "declaration" => "declare",
      "attestation" => "attest",
      "authorization" => "authorize"
    }.freeze

    KIND_FOR_VERB = VERB_FOR_KIND.invert.freeze

    # The action recorded when a statement is first captured.
    INITIAL_ACTION_FOR_KIND = {
      "agreement" => "agreed",
      "acknowledgment" => "acknowledged",
      "consent" => "granted",
      "declaration" => "declared",
      "attestation" => "attested",
      "authorization" => "authorized"
    }.freeze

    # Every action a statement of each kind may ever record.
    ACTIONS_FOR_KIND = {
      "agreement" => %w[agreed superseded].freeze,
      "acknowledgment" => %w[acknowledged superseded expired].freeze,
      "consent" => %w[granted declined withdrawn renewed scope_changed].freeze,
      "declaration" => %w[declared corrected superseded expired].freeze,
      "attestation" => %w[attested corrected superseded].freeze,
      "authorization" => %w[authorized consumed expired revoked].freeze
    }.freeze

    ACTIONS = ACTIONS_FOR_KIND.values.flatten.uniq.freeze

    # Kinds whose meaning includes a withdrawal route. Withdrawing future
    # consent never rewrites a historical agreement or factual declaration, so
    # only `consent` is withdrawable.
    WITHDRAWABLE_KINDS = %w[consent].freeze

    # Kinds that may carry a validity period.
    EXPIRABLE_KINDS = %w[acknowledgment consent declaration authorization].freeze

    # Kinds that may be corrected by the same actor without implying the
    # original statement was false when it was made.
    CORRECTABLE_KINDS = %w[declaration attestation].freeze

    # Kinds that may be scoped to a single protected action.
    ONE_TIME_KINDS = %w[authorization].freeze

    # What produced an event. `capture` is a human action recorded by this
    # application; every other value says plainly that something else happened.
    EVENT_TYPES = %w[
      capture
      withdrawal
      correction
      supersession
      expiry
      consumption
      revocation
      renewal
      scope_change
      exemption
      imported_legacy
      external_receipt
      disposition
      legal_hold_placed
      legal_hold_released
      receipt_access
      provider_outcome
    ].freeze

    # Event types that record an act by a human through a Clickwrap
    # presentation. These satisfy `agreed_to?`, `consented_to?` and the other
    # human-action predicates — as does `imported_legacy`, which carries what a
    # previous system recorded about a human action (an exemption never does:
    # it records that no human acted).
    HUMAN_ACTION_EVENT_TYPES = %w[capture correction renewal scope_change].freeze

    # What belongs in an actor's own receipts collection: every act they
    # performed here, plus their history imported from a previous system or
    # recorded by an external provider. A migrated user's records screen must
    # show their history, not an empty list that implies they never agreed to
    # anything.
    ACTOR_RECEIPT_EVENT_TYPES = (HUMAN_ACTION_EVENT_TYPES + %w[imported_legacy external_receipt]).freeze

    # Where a capture came from. This is recorded, never guessed: a missing
    # browser parameter is not evidence of a system actor.
    CAPTURE_CHANNELS = %w[
      web_browser
      native_app
      api_client
      operator
      background_job
      imported_provider
      system
    ].freeze

    # The current state of one statement for one actor/subject, projected from
    # retained event payloads.
    STATES = %w[
      active
      declined
      withdrawn
      expired
      superseded
      consumed
      revoked
      corrected
      exempted
    ].freeze

    # A statement in one of these states cannot satisfy a requirement.
    INACTIVE_STATES = %w[declined withdrawn expired superseded consumed revoked corrected].freeze

    # How a receipt describes each optional request-evidence field. "Blank" is
    # never allowed to blur "we chose not to collect this" into "collection
    # failed" or "we deleted it".
    REQUEST_EVIDENCE_STATES = %w[
      not_configured
      unavailable
      recorded
      redacted_for_this_viewer
      deleted_after_retention
      held
    ].freeze

    # Every IP-geolocation data field a policy can enable individually.
    # `latitude_and_longitude` is one coupled choice on purpose: half a
    # coordinate is not a result.
    IP_GEOLOCATION_DATA_FIELDS = %w[
      country
      region
      city
      postal_code
      latitude_and_longitude
      timezone
      continent
      metro_code
      accuracy_radius_in_kilometers
    ].freeze

    # The three coarse fields `config.record_request_evidence_by_default = true`
    # turns on. Coarse means administrative area, not a point: a country, a
    # region, and a city are what a provider can estimate from an address with
    # any confidence at all. Everything finer — a postal code, coordinates, a
    # timezone, a metro code — stays its own separately named decision, because
    # a switch that reads "record request evidence" should not hand somebody
    # coordinates they never asked for.
    COARSE_IP_GEOLOCATION_DATA_FIELDS = %w[country region city].freeze

    # The purpose Clickwrap records when a host enables request evidence
    # without writing a purpose of their own. It is the gem's own sentence, not
    # a reviewed host decision, and the privacy inventory says which of the two
    # it is looking at. It exists because the alternative — refusing to boot
    # until somebody writes a sentence — was pushing integrators to record
    # nothing at all, and no corroboration is worse evidence than corroboration
    # collected under the gem's stated purpose.
    DEFAULT_REQUEST_EVIDENCE_PURPOSE =
      "Corroborate who performed each recorded act, from where, on what client — to defend " \
      "the recorded agreement itself."

    # The reason recorded when a host keeps request evidence indefinitely
    # without writing their own. Same posture as the purpose above: the
    # declaration is still recorded and still readable years later; only the
    # obligation to phrase it yourself is gone.
    DEFAULT_REASON_FOR_KEEPING_REQUEST_EVIDENCE_INDEFINITELY =
      "Corroboration lives as long as the evidence it corroborates"

    # Provenance that travels with any stored IP-geolocation result. A policy
    # cannot keep provider-derived coordinates while stripping the uncertainty
    # needed to interpret them.
    IP_GEOLOCATION_PROVENANCE_FIELDS = %w[
      ip_geolocation_provider_name
      ip_geolocation_provider_source
      ip_geolocation_database_version
      ip_geolocation_database_sha256
      ip_geolocation_accuracy_radius_confidence_percentage
      ip_geolocation_was_estimated
      ip_geolocation_source_was_verified_by_host
      ip_geolocation_resolved_at
      ip_geolocation_unavailable_reason
    ].freeze

    # How the actor was attributed to the event. None of these is an identity
    # claim; they say which application-supplied context was recorded.
    ATTRIBUTION_METHODS = %w[
      authenticated_session
      account_registration
      public_form
      operator_session
      api_credential
      anonymous_identifier
      system_process
      imported_provider
      unknown
    ].freeze

    # Stable machine-readable reasons a verification can fail. Applications
    # branch on these symbols; the human message is localized separately.
    VERIFICATION_ERRORS = %i[
      no_evidence
      wrong_actor
      wrong_tenant
      wrong_subject
      subject_fingerprint_mismatch
      stale_policy_revision
      unseen_document_version
      missing_answer
      declined
      declaration_expired
      acknowledgment_expired
      consent_withdrawn
      superseded
      revoked
      authorization_consumed
      authorization_expired
      predecessor_missing
      wrong_order
      replay_rejected
      presentation_expired
      presentation_invalid
      presentation_actor_mismatch
      presentation_subject_mismatch
      presentation_tenant_mismatch
      presentation_channel_mismatch
      presentation_policy_mismatch
      represented_party_mismatch
      represented_party_authority_mismatch
      represented_party_creation_flow_mismatch
      registration_flow_mismatch
      registration_actor_type_mismatch
      document_digest_mismatch
      integrity_check_failed
      exemption_not_accepted
      request_evidence_unavailable
      core_event_disposed
      unknown_policy
      unknown_statement
    ].freeze

    # Which assurance tier a verification result was produced under. Each tier
    # states exactly what it detects and nothing more.
    INTEGRITY_TIERS = %w[
      baseline
      database_hardening
      chained_history
      external_event_anchoring
      third_party_timestamp
    ].freeze

    # Public words that would overclaim what any of this proves. The release
    # test greps generated output, receipts, task output, and documentation for
    # these.
    PROHIBITED_CLAIM_PHRASES = [
      "gdpr compliant",
      "gdpr-compliant",
      "legally compliant",
      "compliance guaranteed",
      "court proof",
      "court-proof",
      "tamper proof",
      "tamper-proof",
      "legally binding",
      "guarantees enforceability",
      "audit guaranteed",
      "qualified electronic signature",
      "trusted time",
      "trusted_timestamp",
      "verified identity",
      "legal advice"
    ].freeze

    class << self
      def kind?(value) = KINDS.include?(value.to_s)
      def action?(value) = ACTIONS.include?(value.to_s)
      def event_type?(value) = EVENT_TYPES.include?(value.to_s)
      def capture_channel?(value) = CAPTURE_CHANNELS.include?(value.to_s)
      def state?(value) = STATES.include?(value.to_s)

      def actions_for(kind)
        ACTIONS_FOR_KIND.fetch(kind.to_s) do
          raise UnknownStatementError, "#{kind.inspect} is not one of: #{KINDS.join(", ")}"
        end
      end

      def initial_action_for(kind)
        INITIAL_ACTION_FOR_KIND.fetch(kind.to_s) do
          raise UnknownStatementError, "#{kind.inspect} is not one of: #{KINDS.join(", ")}"
        end
      end

      def withdrawable?(kind) = WITHDRAWABLE_KINDS.include?(kind.to_s)
      def expirable?(kind) = EXPIRABLE_KINDS.include?(kind.to_s)
      def correctable?(kind) = CORRECTABLE_KINDS.include?(kind.to_s)
      def one_time_allowed?(kind) = ONE_TIME_KINDS.include?(kind.to_s)
      def human_action_event_type?(value) = HUMAN_ACTION_EVENT_TYPES.include?(value.to_s)
      def inactive_state?(value) = INACTIVE_STATES.include?(value.to_s)
    end
  end
end
