# frozen_string_literal: true

module Clickwrap
  # A reviewable plan to delete something.
  #
  # Deletion here is always two steps: plan, then apply. The plan is immutable,
  # scoped, and expiring, and it is rechecked at apply time. A newly placed
  # legal hold, a changed policy, a changed eligibility, or a stale plan stops
  # the run rather than deleting a broader set than the person who reviewed it
  # agreed to.
  #
  # The plan itself never decides whether an erasure request overrides a
  # retention duty, a legal claim, or a hold. It shows what would happen.
  class DispositionPlan < ApplicationRecord
    self.table_name = "clickwrap_disposition_plans"
    self.primary_key = "id"

    KINDS = %w[retention actor_privacy].freeze
    STATES = %w[open applying applied applied_with_errors superseded].freeze

    DEFAULT_LIFETIME = 24.hours

    validates :kind, inclusion: { in: KINDS }
    validates :state, inclusion: { in: STATES }
    validates :expires_at, presence: true
    validates :plan_digest, presence: true

    before_validation :assign_identifier, on: :create
    before_validation :assign_plan_digest, on: :create
    before_update :refuse_ordinary_update
    before_destroy :refuse_destroy, prepend: true

    scope :open_plans, -> { where(state: "open") }
    scope :usable, ->(at = Clickwrap.now) { open_plans.where("expires_at > ?", at) }

    def expired?(at = Clickwrap.now) = expires_at <= at
    def applied? = state == "applied"

    def usable?(at = Clickwrap.now)
      state == "open" && !expired?(at)
    end

    # Raises with the specific reason this plan can no longer be applied, so an
    # operator sees "the plan expired" or "this was already applied" rather than
    # a generic refusal.
    def ensure_usable!(at = Clickwrap.now)
      raise DispositionPlanInvalid, "Disposition plan #{id} failed its immutable plan digest." unless digest_verified?
      return true if usable?(at)

      raise DispositionPlanInvalid,
            case state
            when "applied", "applied_with_errors" then "Disposition plan #{id} was already applied at #{applied_at}."
            when "applying" then "Disposition plan #{id} is already being applied."
            when "superseded" then "Disposition plan #{id} was superseded by a newer plan."
            else "Disposition plan #{id} expired at #{expires_at}. Run the plan again and " \
                 "review the current set before applying it."
            end
    end

    def claim_for_application!(by_reference:, recover_if_stale_after: nil,
                               because_recovery_is_needed: nil)
      if by_reference.to_s.strip.empty?
        raise DispositionPlanInvalid,
              "Applying a disposition plan needs the stable reference of the operator doing it."
      end

      with_lock do
        if state == "applying"
          reclaim_stale_application!(
            by_reference: by_reference,
            stale_after: recover_if_stale_after,
            because: because_recovery_is_needed
          )
        else
          ensure_usable!
          start_application_attempt!(by_reference)
        end
      end
      self
    end

    def finish_application!(outcome_summary:, had_errors: false)
      with_lock do
        unless state == "applying"
          raise DispositionPlanInvalid, "Disposition plan #{id} is not currently being applied."
        end

        update_columns(
          state: had_errors ? "applied_with_errors" : "applied",
          applied_at: Clickwrap.now,
          application_outcome: outcome_summary
        )
      end
      self
    end

    def supersede!(because:, by:)
      raise DispositionPlanInvalid, "Superseding a plan needs a `because:`." if because.to_s.strip.empty?

      with_lock do
        ensure_usable!
        update_columns(
          state: "superseded",
          superseded_at: Clickwrap.now,
          superseded_by_reference: Reference.actor(by),
          superseded_reason: because
        )
      end
      self
    end

    def digest_verified?
      Digest.secure_compare?(plan_digest.to_s, compute_plan_digest)
    end

    def to_s = "#{kind} disposition plan #{id} (#{item_count} items)"

    private

    def assign_identifier
      self.id ||= Identifier.generate
      self.expires_at ||= Clickwrap.now + DEFAULT_LIFETIME
      self.created_at ||= Clickwrap.now
      self.updated_at ||= created_at
    end

    def assign_plan_digest
      self.plan_digest ||= compute_plan_digest
    end

    def compute_plan_digest
      Digest.digest_canonical({
                                "id" => id,
                                "kind" => kind,
                                "scope" => disposition_scope,
                                "summary" => summary,
                                "item_count" => item_count,
                                "created_by_reference" => created_by_reference,
                                "reason" => reason,
                                "expires_at" => Receipt.format_time(expires_at),
                                "created_at" => Receipt.format_time(created_at)
                              })
    end

    def start_application_attempt!(by_reference)
      started_at = Clickwrap.now
      update_columns(
        state: "applying",
        application_started_at: started_at,
        applied_by_reference: by_reference.to_s,
        application_attempt_count: application_attempt_count.to_i + 1,
        updated_at: started_at
      )
    end

    def reclaim_stale_application!(by_reference:, stale_after:, because:)
      raise DispositionPlanInvalid, "Disposition plan #{id} expired at #{expires_at}." if expired?

      unless stale_after.respond_to?(:positive?) && stale_after.positive?
        raise DispositionPlanInvalid,
              "Disposition plan #{id} is already being applied. Recovering it requires " \
              "recover_application_if_stale_for with a positive duration."
      end

      cutoff = Clickwrap.now - stale_after
      if application_started_at.present? && application_started_at > cutoff
        raise DispositionPlanInvalid,
              "Disposition plan #{id} has only been applying since #{application_started_at}; " \
              "it is not older than the #{stale_after.inspect} recovery threshold."
      end

      if because.to_s.strip.empty?
        raise DispositionPlanInvalid,
              "Recovering a stale disposition application needs " \
              "because_recovery_is_needed in plain English."
      end

      recovered_at = Clickwrap.now
      recoveries = Array(application_recoveries).dup
      recoveries << {
        "previous_application_started_at" => Receipt.format_time(application_started_at),
        "previous_applied_by_reference" => applied_by_reference,
        "recovered_at" => Receipt.format_time(recovered_at),
        "recovered_by_reference" => by_reference.to_s,
        "reason" => because.to_s.strip
      }.compact

      update_columns(
        application_started_at: recovered_at,
        applied_by_reference: by_reference.to_s,
        application_attempt_count: application_attempt_count.to_i + 1,
        application_recoveries: recoveries,
        updated_at: recovered_at
      )
    end

    def refuse_ordinary_update
      raise ImmutableEvidenceError,
            "Disposition plans refuse ordinary updates. Use claim_for_application!, " \
            "finish_application!, or supersede!(because:, by:) for a named transition."
    end

    def refuse_destroy
      raise ImmutableEvidenceError,
            "Disposition plans cannot be destroyed; their reviewed scope and named transitions must remain."
    end
  end
end
