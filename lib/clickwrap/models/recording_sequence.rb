# frozen_string_literal: true

module Clickwrap
  # One database-assigned number for each evidence event. The row exists so the
  # database's native auto-increment/sequence mechanism—not an application
  # clock, process-local counter, or lexicographically sortable public ID—owns
  # the ordering. Precisely: the number is allocated at INSERT time, not at
  # COMMIT time, so two concurrent transactions can commit in the opposite
  # order of their numbers. Within one statement identity the actor lock makes
  # allocation order and commit order agree — which is the guarantee
  # `recorded_after?` relies on. Do not build an outbox or cursor pagination
  # on this column; it is an ordering key for evidence questions, not a
  # commit-ordered feed.
  #
  # Gaps are expected when a transaction rolls back. Ordering asks only whether
  # one committed event's number is greater than another's; it never assumes
  # numbers are contiguous or reveals them as the public event identifier.
  class RecordingSequence < ApplicationRecord
    self.table_name = "clickwrap_recording_sequences"
  end
end
