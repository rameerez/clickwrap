# frozen_string_literal: true

module Clickwrap
  # The current-state projection: the answer to "does this person currently have
  # X?" without walking the whole event history on every request.
  #
  # This table is a cache of a computation over immutable events, and it can be
  # rebuilt from them at any time. Nothing here is evidence — the evidence is in
  # `clickwrap_events`. That separation is what lets this row be mutable,
  # indexed, and fast without any of those properties leaking into the record of
  # what actually happened.
  #
  # The unique index on identity is doing real work: it is what stops two
  # concurrent submits from producing two live grants, or two usable
  # authorizations for the same actor and subject.
  class StatementState < ApplicationRecord
    self.table_name = "clickwrap_statement_states"

    belongs_to :actor, polymorphic: true, optional: true
    belongs_to :subject, polymorphic: true, optional: true
    belongs_to :policy_revision, class_name: "Clickwrap::PolicyRevision", optional: true

    validates :policy_key, :statement_key, :actor_reference, :current_event_id, presence: true
    validates :kind, inclusion: { in: Vocabulary::KINDS }
    validates :state, inclusion: { in: Vocabulary::STATES }

    scope :active, -> { where(state: "active") }
    scope :for_actor, ->(reference) { where(actor_reference: reference) }
    scope :for_policy, ->(key) { where(policy_key: key.to_s) }
    scope :for_statement, ->(key) { where(statement_key: key.to_s) }
    scope :for_purpose, ->(key) { where(purpose_key: key.to_s) }
    scope :expiring_before, ->(moment) { where.not(expires_at: nil).where(expires_at: ...moment) }

    scope :due_for_expiry, lambda { |at = Clickwrap.now|
      active.where.not(expires_at: nil).where(expires_at: ...at)
    }

    # The identity a unique index can enforce. NULLs do not collide in a unique
    # index on most adapters, so "no tenant" and "no subject" are the empty
    # string rather than NULL — otherwise a policy with no subject would happily
    # accumulate duplicate live grants.
    def self.identity_for(policy_key:, statement_key:, actor_reference:, tenant_key: nil, subject_key: nil)
      {
        policy_key: policy_key.to_s,
        statement_key: statement_key.to_s,
        actor_reference: actor_reference.to_s,
        tenant_key: tenant_key.to_s,
        subject_key: subject_key.to_s
      }
    end

    def self.subject_key_for(subject)
      return "" if subject.nil?
      return subject.to_s if subject.is_a?(String)
      return subject.to_gid.to_s if subject.respond_to?(:to_gid)

      "#{subject.class.name}/#{subject.id}"
    end

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
      when "superseded" then :superseded
      when "revoked" then :revoked
      when "consumed" then :authorization_consumed
      when "corrected" then :superseded
      when "exempted" then :exemption_not_accepted
      when "expired" then expiry_error
      else expired?(at) ? expiry_error : :no_evidence
      end
    end

    def to_s = "#{kind} #{statement_key} for #{actor_reference} (#{state})"

    private

    def expiry_error
      case kind
      when "declaration" then :declaration_expired
      when "acknowledgment" then :acknowledgment_expired
      when "authorization" then :authorization_expired
      else :declaration_expired
      end
    end
  end
end
