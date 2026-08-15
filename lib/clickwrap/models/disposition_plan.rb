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
    STATES = %w[open applied expired superseded].freeze

    DEFAULT_LIFETIME = 24.hours

    validates :kind, inclusion: { in: KINDS }
    validates :state, inclusion: { in: STATES }
    validates :expires_at, presence: true

    before_validation :assign_identifier, on: :create

    scope :open_plans, -> { where(state: "open") }
    scope :usable, ->(at = Clickwrap.now) { open_plans.where(expires_at: at...) }

    def expired?(at = Clickwrap.now) = expires_at <= at
    def applied? = state == "applied"

    def usable?(at = Clickwrap.now)
      state == "open" && !expired?(at)
    end

    # Raises with the specific reason this plan can no longer be applied, so an
    # operator sees "the plan expired" or "this was already applied" rather than
    # a generic refusal.
    def ensure_usable!(at = Clickwrap.now)
      return true if usable?(at)

      raise DispositionPlanInvalid,
            case state
            when "applied" then "Disposition plan #{id} was already applied at #{applied_at}."
            when "superseded" then "Disposition plan #{id} was superseded by a newer plan."
            else "Disposition plan #{id} expired at #{expires_at}. Run the plan again and " \
                 "review the current set before applying it."
            end
    end

    def mark_applied!(by_reference:)
      update!(state: "applied", applied_at: Clickwrap.now, applied_by_reference: by_reference.to_s)
    end

    def to_s = "#{kind} disposition plan #{id} (#{item_count} items)"

    private

    def assign_identifier
      self.id ||= Identifier.generate
      self.expires_at ||= Clickwrap.now + DEFAULT_LIFETIME
    end
  end
end
