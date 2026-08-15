# frozen_string_literal: true

module Clickwrap
  # A record of one presentation manifest.
  #
  # Most presentations never become rows. The default path signs the manifest
  # into a short-lived token and writes nothing on GET, because a render is not
  # evidence and a row per page view is both slower and more personal data than
  # the job needs.
  #
  # Rows appear in two cases. A policy can explicitly retain pre-submit
  # presentations for a documented reason, which some high-assurance flows want
  # so that display attempts are visible. And every successful capture persists
  # the manifest it accepted, because that one is part of the evidence.
  #
  # The `state` vocabulary is deliberately careful. `presented_by_server` means
  # the server generated and offered this manifest — not that anyone saw it, not
  # that anyone read it, and certainly not that anyone accepted it.
  class Presentation < ApplicationRecord
    self.table_name = "clickwrap_presentations"

    STATES = %w[presented_by_server accepted rejected expired].freeze

    belongs_to :policy_revision, class_name: "Clickwrap::PolicyRevision", inverse_of: :presentations
    belongs_to :actor, polymorphic: true, optional: true
    belongs_to :subject, polymorphic: true, optional: true

    has_many :events,
             class_name: "Clickwrap::Event",
             foreign_key: :presentation_id,
             inverse_of: :presentation,
             dependent: :restrict_with_error

    validates :policy_key, :nonce, :manifest_digest, :issued_at, :expires_at, presence: true
    validates :nonce, uniqueness: true
    validates :state, inclusion: { in: STATES }
    validates :capture_channel, inclusion: { in: Vocabulary::CAPTURE_CHANNELS }

    scope :pending, -> { where(state: "presented_by_server") }
    scope :expired_at, ->(moment = Clickwrap.now) { where(expires_at: ...moment) }
    scope :due_for_disposition, lambda { |at = Clickwrap.now|
      where.not(retain_until: nil).where(retain_until: ...at)
    }

    def expired?(at = Clickwrap.now) = expires_at <= at
    def accepted? = state == "accepted"

    def mark_accepted!(at: Clickwrap.now)
      update!(state: "accepted", submitted_at: at)
    end

    def mark_rejected!(at: Clickwrap.now)
      update!(state: "rejected", submitted_at: at)
    end

    def to_s = "presentation #{nonce} for #{policy_key}"
  end
end
