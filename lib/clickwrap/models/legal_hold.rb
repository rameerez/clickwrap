# frozen_string_literal: true

module Clickwrap
  # A legal hold pauses scheduled disposition for an event, an actor, or a
  # policy.
  #
  # It requires a reason, an owner, and a review date. That is not bureaucracy:
  # an indefinite hold with no owner is exactly how "we'll delete it later"
  # becomes "we kept everything forever", and a retention policy that can be
  # suspended invisibly is not a retention policy. The hold is itself
  # append-only evidence, and releasing one records who released it and why.
  class LegalHold < ApplicationRecord
    self.table_name = "clickwrap_legal_holds"
    self.record_timestamps = false

    SCOPES = %w[event actor policy].freeze

    belongs_to :event, class_name: "Clickwrap::Event", optional: true, inverse_of: :legal_holds

    validates :reason, :placed_by_reference, :placed_at, :review_on, presence: true
    validates :scope, inclusion: { in: SCOPES }
    validate :scope_has_its_target

    scope :in_effect, -> { where(released_at: nil) }
    scope :due_for_review, ->(at = Clickwrap.now) { in_effect.where(review_on: ..at) }
    scope :for_event, ->(id) { where(event_id: id) }
    scope :for_actor, ->(reference) { where(actor_reference: reference) }

    def released? = released_at.present?
    def in_effect? = !released?

    def release!(because:, released_by:)
      raise LegalHoldInEffect, "Releasing a legal hold needs a `because:` explaining why." if because.to_s.strip.empty?

      update!(released_at: Clickwrap.now, released_by_reference: released_by.to_s, release_reason: because)
    end

    def to_s = "legal hold on #{scope} (#{reason})"

    private

    def scope_has_its_target
      target = case scope
               when "event" then event_id
               when "actor" then actor_reference
               when "policy" then policy_key
               end

      return if target.present?

      errors.add(:base, "A #{scope}-scoped legal hold must name the #{scope} it holds.")
    end
  end
end
