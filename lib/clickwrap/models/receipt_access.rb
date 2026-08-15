# frozen_string_literal: true

module Clickwrap
  # A record of who read a receipt, what they were shown, and why.
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
    validates :channel, inclusion: { in: CHANNELS }

    scope :recent_first, -> { order(accessed_at: :desc) }

    def self.record!(event:, requested_by:, because:, included_fields:, channel: "api")
      create!(
        event_id: event.is_a?(String) ? event : event.id,
        requested_by_reference: requested_by&.to_s,
        reason: because,
        included_fields: included_fields,
        channel: channel,
        accessed_at: Clickwrap.now,
        created_at: Clickwrap.now
      )
    end

    def to_s = "access to #{event_id} by #{requested_by_reference}"
  end
end
