# frozen_string_literal: true

module Clickwrap
  # The current-state projection: the answer to "does this person currently have
  # X?" without walking the whole event history on every request.
  #
  # This table is a cache of a computation over retained event payloads. Nothing
  # here is evidence — the evidence is in `clickwrap_events`. Before retention
  # disposes of a root payload it can be rebuilt from those events; afterward,
  # deleting this projection would try to recreate personal identity facts that
  # the reviewed disposition intentionally removed. `CurrentState.rebuild_for!`
  # therefore refuses that destructive operation when it can see such a root.
  # That separation lets this row be mutable, indexed, and fast without those
  # properties leaking into the evidence record.
  #
  # The unique index guarantees one projection row per identity. Portable
  # StatementIdentityLock rows serialize writers; the unique index alone would
  # not stop two immutable capture events or decide which one is current.
  class StatementState < ApplicationRecord
    self.table_name = "clickwrap_statement_states"

    belongs_to :actor, polymorphic: true, optional: true
    belongs_to :subject, polymorphic: true, optional: true
    belongs_to :policy_revision, class_name: "Clickwrap::PolicyRevision", optional: true

    validates :policy_key, :statement_key, :actor_reference, :current_event_id, presence: true
    validates :identity_digest, presence: true

    # Recomputed on every save rather than only on create: if any part of the
    # identity is ever corrected, the digest has to follow it or the unique
    # index would be guarding a value nothing matches.
    before_validation :assign_identity_digest
    validates :kind, inclusion: { in: Vocabulary::KINDS }
    validates :state, inclusion: { in: Vocabulary::STATES }

    scope :active, -> { where(state: "active") }
    scope :for_actor, ->(reference) { where(actor_reference: reference) }
    scope :for_policy, ->(key) { where(policy_key: key.to_s) }
    scope :for_statement, ->(key) { where(statement_key: key.to_s) }
    scope :for_purpose, ->(key) { where(purpose_key: key.to_s) }
    scope :expiring_before, ->(moment) { where.not(expires_at: nil).where(expires_at: ...moment) }

    scope :due_for_expiry, lambda { |at = Clickwrap.now|
      active.where.not(expires_at: nil).where(expires_at: ..at)
    }

    # The identity a unique index can enforce. NULLs do not collide in a unique
    # index on most adapters, so "no tenant" and "no subject" are the empty
    # string rather than NULL — otherwise a policy with no subject would happily
    # accumulate duplicate live grants.
    def self.identity_for(policy_key:, statement_key:, actor_reference:, tenant_key: nil,
                          subject_key: nil, represented_party_reference: nil)
      attributes = {
        policy_key: policy_key.to_s,
        statement_key: statement_key.to_s,
        actor_reference: actor_reference.to_s,
        tenant_key: tenant_key.to_s,
        subject_key: subject_key.to_s,
        represented_party_reference: represented_party_reference.to_s
      }

      attributes.merge(identity_digest: identity_digest_for(attributes))
    end

    # The digest the unique index is taken over. Canonicalized first, so the
    # value depends on the five parts and not on the order a caller happened to
    # build the hash in.
    def self.identity_digest_for(attributes)
      Digest.digest_canonical(attributes.transform_keys(&:to_s))
    end

    def self.subject_key_for(subject) = Reference.subject(subject)
    def self.tenant_key_for(tenant) = Reference.tenant(tenant)

    def current_event = Event.find_by(id: current_event_id)

    def expired?(at = Clickwrap.now) = expires_at.present? && expires_at <= at

    # Whether this projection currently satisfies a requirement. Expiry is
    # evaluated live rather than trusted from the `state` column, because a
    # declaration expires on a clock, not on a background job having run.
    def satisfies?(at = Clickwrap.now)
      return false unless state == "active"
      return false if expired?(at)

      true
    end

    # Why it does not, as one of the stable error symbols applications branch
    # on. Never an English string: an authorization decision should not depend
    # on parsing a message.
    def failure_reason(at = Clickwrap.now)
      return nil if satisfies?(at)

      case state
      when "withdrawn" then :consent_withdrawn
      when "declined" then :declined
      when "superseded", "corrected" then :superseded
      when "revoked" then :revoked
      when "consumed" then :authorization_consumed
      when "exempted" then :exemption_not_accepted
      when "expired" then expiry_error
      else expired?(at) ? expiry_error : :no_evidence
      end
    end

    def to_s = "#{kind} #{statement_key} for #{actor_reference} (#{state})"

    private

    def assign_identity_digest
      self.identity_digest = self.class.identity_digest_for(
        policy_key: policy_key.to_s,
        statement_key: statement_key.to_s,
        actor_reference: actor_reference.to_s,
        tenant_key: tenant_key.to_s,
        subject_key: subject_key.to_s,
        represented_party_reference: represented_party_reference.to_s
      )
    end

    def expiry_error
      case kind
      when "acknowledgment" then :acknowledgment_expired
      when "authorization" then :authorization_expired
      else :declaration_expired
      end
    end
  end
end
