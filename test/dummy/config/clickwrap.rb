# frozen_string_literal: true

# The dummy host's documents, policies, and retention classes — the same file a
# real application writes, loaded by the engine's to_prepare.
#
# Between them these cover every kind, every lifecycle, the subject-fingerprint
# and one-time-authorization paths, optional consent with a withdrawal route,
# operator attestation, an exemption-permitting policy, and a policy that records
# request evidence — so the suite exercises the real compiler rather than fixtures.

Clickwrap.document :terms,
                   version: "2026-08-15",
                   locale: :en,
                   from: Rails.root.join("app/content/legal/terms.md")

Clickwrap.document :privacy_notice,
                   version: "2026-08-15",
                   locale: :en,
                   from: Rails.root.join("app/content/legal/privacy.md")

Clickwrap.document :marketing_notice,
                   version: "2026-08-15",
                   locale: :en,
                   from: Rails.root.join("app/content/legal/marketing.md")

Clickwrap.document :withdrawal_requirements,
                   version: "2026-08-15",
                   locale: :en,
                   from: Rails.root.join("app/content/legal/withdrawal_requirements.md")

Clickwrap.document :driver_declaration,
                   version: "2026-08-15",
                   locale: :en,
                   from: Rails.root.join("app/content/legal/driver_declaration.md")

# --- Retention classes -------------------------------------------------------

Clickwrap.retention :ordinary_agreement_evidence do
  retain_core_event_for 6.years
  delete_recorded_ip_address_after 90.days
  delete_recorded_browser_user_agent_after 90.days
  delete_recorded_ip_geolocation_after 90.days
end

Clickwrap.retention :marketing_consent_evidence do
  retain_core_event_for 3.years
end

# The event-based case: a duration alone cannot express "five years, or three
# years after this is liquidated, whichever is later". The calculation is
# registered on the configuration and may legitimately return nil while the host
# event has not happened, which the disposition planner reports as unresolved
# rather than treating as due.
Clickwrap.retention :regulated_evidence do
  retain_core_event_until :regulated_evidence_retention_ends
  retain_recorded_ip_address_until :security_evidence_retention_ends
  retain_recorded_browser_user_agent_until :security_evidence_retention_ends
  retain_recorded_ip_geolocation_until :security_evidence_retention_ends
end

# --- Policies ----------------------------------------------------------------

# The five-minute path. Note the two different verbs: Terms are agreed to, a
# privacy notice is acknowledged. They are different acts with different
# lifecycles, and collapsing them would record something that did not happen.
Clickwrap.policy :signup do
  agree_to :terms
  acknowledge :privacy_notice

  retain_with :ordinary_agreement_evidence
end

# Reacceptance: evidence against an older published version stops satisfying
# this one. The application decides which change is material; Clickwrap enforces
# the rule it is given.
Clickwrap.policy :current_terms do
  tenant_is :not_applicable
  agree_to :terms, require_current_version: true

  retain_with :ordinary_agreement_evidence
end

# Tenant-scoped marketing consent (the default `tenant_is :optional`): the
# engine's tenant-aware withdrawal tests exercise this shape.
Clickwrap.policy :marketing_preferences do
  consent_to :product_updates,
             document: :marketing_notice,
             statement: "I agree to receive product update emails.",
             optional: true,
             withdrawal_path: "/settings/privacy"

  consent_to :partner_offers,
             document: :marketing_notice,
             statement: "I agree to receive offers from selected partners.",
             optional: true,
             withdrawal_path: "/settings/privacy"

  retain_with :marketing_consent_evidence
end

# Personal marketing consent (`tenant_is :not_applicable`): joining or
# switching organizations must never change what this consent means or hide
# it from withdrawal.
Clickwrap.policy :personal_newsletter do
  tenant_is :not_applicable

  consent_to :personal_newsletter,
             document: :marketing_notice,
             statement: "I agree to receive the newsletter.",
             optional: true,
             withdrawal_path: "/settings/privacy"

  retain_with :marketing_consent_evidence
end

# A recorded yes/no decision, for when the absence of a grant is not a good
# enough answer. Both controls start unselected.
Clickwrap.policy :research_contact do
  consent_to :research_contact,
             document: :marketing_notice,
             statement: "You may contact me about product research.",
             choices: { yes: :grant, no: :decline },
             require_an_explicit_choice: true,
             withdrawal_path: "/settings/privacy"

  retain_with :marketing_consent_evidence
end

Clickwrap.policy :driver_declaration do
  declare :non_professional_driver,
          document: :driver_declaration,
          statement: "I declare that I drive privately and not as a professional driver.",
          valid_for: 1.year,
          subject_fingerprint_version: "withdrawal-evidence-v1",
          subject_fingerprint_with: ->(scheme) { scheme.evidence_fingerprint }

  retain_with :regulated_evidence
end

# The high-assurance case: several explicit assertions, a subject fingerprint, an
# ordering requirement, and a one-time authorization consumed inside the same
# transaction as the withdrawal it authorizes.
Clickwrap.policy :withdrawal_authorization do
  acknowledge :withdrawal_requirements,
              statement: "I acknowledge the withdrawal requirements."

  declare :ride_exclusivity,
          document: :withdrawal_requirements,
          statement: "I declare that these rides have not been claimed for any other payout.",
          subject_fingerprint_version: "covered-rides-v1",
          subject_fingerprint_with: ->(withdrawal) { withdrawal.covered_rides_fingerprint }

  authorize :withdrawal,
            document: :withdrawal_requirements,
            statement: "I authorize this withdrawal.",
            one_time: true,
            valid_for: 10.minutes,
            requires: %i[withdrawal_requirements ride_exclusivity],
            protected_outcome_version: "submitted-withdrawal-v1",
            record_protected_outcome_with: lambda { |withdrawal|
              Clickwrap.protected_outcome(
                action: :submitted,
                record: withdrawal,
                state: withdrawal.state,
                facts: {
                  amount_in_cents: withdrawal.amount_cents,
                  covered_ride_ids: withdrawal.covered_ride_ids
                }
              )
            }

  retain_with :regulated_evidence
end

# Operator attestations: which authorized person asserted which operational fact.
Clickwrap.policy :manual_bank_transfer do
  attest :beneficiary_matches_verified_identity,
         document: :withdrawal_requirements,
         statement: "I attest that the beneficiary matches the verified identity on file."

  attest :bank_accepted_transfer,
         document: :withdrawal_requirements,
         statement: "I attest that the bank accepted this transfer."

  only_capture_from :operator

  retain_with :regulated_evidence
end

# Seeds and imports need an explicit, recorded way to say no human acted. An
# exemption never satisfies `agreed_to?` even when a policy permits it.
Clickwrap.policy :seeded_signup do
  agree_to :terms
  acknowledge :privacy_notice

  permit_exemptions because: "Demo and seed accounts are created without a human signup"

  retain_with :ordinary_agreement_evidence
end

# The evidence-rich case. Every field is named, every category has a purpose and
# a retention rule, and the review date is set — which is what the compiler
# requires before it will record any of it.
Clickwrap.policy :regulated_authorization do
  authorize :regulated_action,
            document: :withdrawal_requirements,
            statement: "I authorize this regulated action.",
            one_time: true,
            valid_for: 10.minutes

  persist_presentations_before_submission_for 30.days,
                                              because: "Investigate disputes about this regulated authorization"

  review_request_evidence_configuration_on Date.new(2027, 8, 15)

  record_ip_address(
    encrypted: true,
    retain_until: :security_evidence_retention_ends,
    because: "Investigate account compromise and disputes about this action",
    legal_basis_reference: "DUMMY-LIA-SECURITY-2026-01"
  )

  record_browser_user_agent(
    encrypted: true,
    retain_until: :security_evidence_retention_ends,
    because: "Corroborate the client context used for this action",
    legal_basis_reference: "DUMMY-LIA-SECURITY-2026-01"
  )

  record_ip_geolocation(
    country: true,
    region: true,
    city: true,
    latitude_and_longitude: true,
    accuracy_radius_in_kilometers: true,
    retain_until: :security_evidence_retention_ends,
    because: "Corroborate anomalous access and investigate action disputes",
    legal_basis_reference: "DUMMY-LIA-SECURITY-2026-01",
    data_protection_impact_assessment_reference: "DUMMY-DPIA-2026-04"
  )

  retain_with :regulated_evidence
end
