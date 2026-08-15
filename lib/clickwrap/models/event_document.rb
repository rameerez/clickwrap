# frozen_string_literal: true

module Clickwrap
  # The exact document version bound to one statement in one event, with the
  # digests as they stood at capture.
  #
  # The digests are copied here rather than only referenced, so that verification
  # can detect a document version row that was edited in place instead of
  # trusting the current value of a column it is supposed to be checking.
  class EventDocument < ApplicationRecord
    self.table_name = "clickwrap_event_documents"
    self.record_timestamps = false

    belongs_to :event, class_name: "Clickwrap::Event", inverse_of: :documents
    belongs_to :document_version,
               class_name: "Clickwrap::DocumentVersion",
               optional: true,
               inverse_of: :event_documents

    validates :statement_key, :document_key, :version_label, :locale, :content_digest,
              presence: true

    before_update :refuse_change
    before_destroy :refuse_destroy

    # True when the stored document version still carries the digest this event
    # recorded. A false says the document row changed after capture — which is
    # a finding, not a crash, so verification reports it with a stable error
    # rather than raising into an export.
    def still_matches_stored_version?
      return false if document_version.nil?

      Digest.secure_compare?(document_version.content_digest, content_digest)
    end

    def canonical_fragment
      {
        "statement" => statement_key,
        "key" => document_key,
        "version" => version_label,
        "locale" => locale,
        "media_type" => media_type,
        "digest" => content_digest,
        "rendered_digest" => rendered_content_digest
      }.compact
    end

    def to_s = "#{document_key} #{version_label} (#{locale})"

    private

    def refuse_change
      raise EventWriteFailed,
            "Document binding #{self} on event #{event_id} is an immutable snapshot."
    end

    def refuse_destroy
      raise EventWriteFailed,
            "Document binding #{self} on event #{event_id} cannot be destroyed."
    end
  end
end
