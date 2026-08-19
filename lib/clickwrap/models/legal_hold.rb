# frozen_string_literal: true

module Clickwrap
  # A legal hold pauses scheduled disposition for an event, an actor, or a
  # policy.
  #
  # It requires a reason, an owner, and a review date. That is not bureaucracy:
  # an indefinite hold with no owner is exactly how "we'll delete it later"
  # becomes "we kept everything forever", and a retention policy that can be
  # suspended invisibly is not a retention policy. Placement and release append
  # linked lifecycle events; this row is the current operational projection and
  # changes only through the named `release!` transition.
  class LegalHold < ApplicationRecord
    self.table_name = "clickwrap_legal_holds"
    self.record_timestamps = false

    SCOPES = %w[event actor policy].freeze

    belongs_to :event, class_name: "Clickwrap::Event", optional: true, inverse_of: :legal_holds

    validates :reason, :placed_by_reference, :placed_at, :review_at, presence: true
    validates :hold_scope, inclusion: { in: SCOPES }
    validate :scope_has_its_target
    validate :review_follows_placement
    before_update :refuse_ordinary_update
    before_destroy :refuse_destroy, prepend: true

    scope :in_effect, -> { where(released_at: nil) }
    scope :due_for_review, ->(at = Clickwrap.now) { in_effect.where(review_at: ..at) }
    scope :for_event, ->(id) { where(event_id: id) }
    scope :for_actor, ->(reference) { where(actor_reference: reference) }

    def released? = released_at.present?
    def in_effect? = !released?

    def release!(because:, released_by:)
      raise LegalHoldInEffect, "Releasing a legal hold needs a `because:` explaining why." if because.to_s.strip.empty?
      raise LegalHoldInEffect, "Legal hold #{id} was already released at #{released_at}." if released?

      update_columns(
        released_at: Clickwrap.now,
        released_by_reference: Reference.actor(released_by),
        release_reason: because
      )
      self
    end

    def to_s = "legal hold on #{hold_scope} (#{reason})"

    private

    def refuse_ordinary_update
      raise ImmutableEvidenceError,
            "Legal holds refuse ordinary updates. Release one through " \
            "`release!(because:, released_by:)`, which records the named transition."
    end

    def refuse_destroy
      raise ImmutableEvidenceError,
            "Legal holds cannot be destroyed; release one through the named transition so its history remains."
    end

    def scope_has_its_target
      target = case hold_scope
               when "event" then event_id
               when "actor" then actor_reference
               when "policy" then policy_key
               end

      return if target.present?

      errors.add(:base, "A #{hold_scope}-scoped legal hold must name the #{hold_scope} it holds.")
    end

    def review_follows_placement
      return if placed_at.nil? || review_at.nil? || review_at > placed_at

      errors.add(:review_at, "must be after the hold was placed")
    end
  end
end
