# frozen_string_literal: true

module Clickwrap
  # One database-assigned number for each evidence event. The row exists so the
  # database's native auto-increment/sequence mechanism—not an application
  # clock, process-local counter, or lexicographically sortable public ID—owns a
  # total durable order across actors and app processes.
  #
  # Gaps are expected when a transaction rolls back. Ordering asks only whether
  # one committed event's number is greater than another's; it never assumes
  # numbers are contiguous or reveals them as the public event identifier.
  class RecordingSequence < ApplicationRecord
    self.table_name = "clickwrap_recording_sequences"
  end
end
