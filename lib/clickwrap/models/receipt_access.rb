# frozen_string_literal: true

module Clickwrap
  # A record of who read a receipt, what the export revealed, and why.
  #
  # Unredacted request evidence needs host authorization plus a human-readable
  # reason, and asking for it appends a row here. The table is plain and
  # queryable on purpose: an access log nobody can read is not much of a
  # control.
  class ReceiptAccess < ApplicationRecord
    self.table_name = "clickwrap_receipt_accesses"
    self.record_timestamps = false

    CHANNELS = %w[api web export task].freeze

    belongs_to :event, class_name: "Clickwrap::Event", inverse_of: :accesses

    validates :event_id, :accessed_at, presence: true
    validates :access_channel, inclusion: { in: CHANNELS }

    before_update :refuse_update
    before_destroy :refuse_destroy, prepend: true

    scope :recent_first, -> { order(accessed_at: :desc) }

    def self.record!(event:, requested_by:, because:, included_fields:, access_channel: "api")
      create!(
        event_id: event.is_a?(String) ? event : event.id,
        requested_by_reference: Reference.actor(requested_by),
        reason: because,
        included_fields: included_fields,
        access_channel: access_channel,
        accessed_at: Clickwrap.now,
        created_at: Clickwrap.now
      )
    end

    def to_s = "access to #{event_id} by #{requested_by_reference}"

    private

    def refuse_update
      raise ImmutableEvidenceError,
            "Receipt access records cannot be updated through Clickwrap. " \
            "Record a new access instead of editing this one."
    end

    def refuse_destroy
      raise ImmutableEvidenceError,
            "Receipt access records cannot be destroyed through Clickwrap."
    end
  end
end
