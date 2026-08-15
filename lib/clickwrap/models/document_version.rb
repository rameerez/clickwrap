# frozen_string_literal: true

module Clickwrap
  # An immutable published version of a document.
  #
  # Once `published_at` is set, the bytes and their digest are frozen. There is
  # no supported way to edit them: a change is a new version, and the old row
  # stays exactly as it was because a receipt from last year points at it.
  #
  # `content_digest` covers the original source bytes. `rendered_content_digest`
  # covers the representation actually offered when a source format was
  # transformed for display. Keeping both is what lets a receipt distinguish
  # "this Markdown file existed" from "the server offered this rendered HTML"
  # instead of letting one claim borrow the other's credibility.
  class DocumentVersion < ApplicationRecord
    self.table_name = "clickwrap_document_versions"

    STORAGE_BACKENDS = %w[database active_storage resolver].freeze

    belongs_to :document, class_name: "Clickwrap::Document", inverse_of: :versions

    has_many :event_documents,
             class_name: "Clickwrap::EventDocument",
             foreign_key: :document_version_id,
             inverse_of: :document_version,
             dependent: :restrict_with_error

    validates :version_label, :locale, :media_type, :content_digest, presence: true
    validates :version_label, uniqueness: { scope: %i[document_id locale] }
    validates :storage_backend, inclusion: { in: STORAGE_BACKENDS }

    scope :published, -> { where.not(published_at: nil) }
    scope :for_locale, ->(locale) { where(locale: locale.to_s) }
    scope :effective_at_or_before, ->(moment) { where(effective_at: ..moment).or(where(effective_at: nil)) }
    scope :not_retired_at, ->(moment) { where(retired_at: nil).or(where(retired_at: moment...)) }

    # Publishing freezes content. Editing a published version is refused here
    # rather than in a code review, because the whole promise of this table is
    # that its rows do not change.
    before_update :refuse_to_change_published_version
    before_destroy :refuse_to_destroy_published_version, prepend: true

    def published? = published_at.present?
    def retired? = retired_at.present?

    def presentable_at?(moment = Clickwrap.now)
      published? &&
        (effective_at.nil? || effective_at <= moment) &&
        (retired_at.nil? || retired_at > moment)
    end

    # Reads the bytes for this version, from wherever the storage adapter put
    # them, and verifies them against the recorded digest before returning.
    # Verification is not optional: silently returning bytes that no longer
    # match would turn this method into a way to launder edited content into an
    # export.
    def content_bytes
      bytes = read_bytes

      unless Digest.matches?(bytes, "#{content_digest_algorithm}:#{bare_digest(content_digest)}")
        raise DocumentDigestMismatchError,
              "The stored bytes for document version #{self} no longer match the digest " \
              "recorded when it was published. The evidence that references this version " \
              "cannot be reproduced until that is explained. Recorded: #{content_digest}."
      end

      bytes
    end

    def verify_content_digest
      content_bytes
      true
    rescue DocumentDigestMismatchError, DocumentNotPublishedError
      false
    end

    def rendered_bytes
      return content_bytes if rendered_content.nil?

      unless rendered_content_digest.present? && Digest.matches?(rendered_content, rendered_content_digest)
        raise DocumentDigestMismatchError,
              "The rendered bytes for document version #{self} no longer match the digest " \
              "recorded when they were published."
      end

      rendered_content
    end

    def verify_rendered_content_digest
      rendered_bytes
      true
    rescue DocumentDigestMismatchError, DocumentNotPublishedError
      false
    end

    def retire!(because:, at: Clickwrap.now)
      raise DocumentVersionConflictError, "Retiring a document version needs a `because:`." if because.to_s.strip.empty?
      raise DocumentVersionConflictError, "Document version #{self} is already retired." if retired?

      update_columns(retired_at: at, retired_reason: because)
      self
    end

    def prefixed_content_digest = content_digest

    def to_s = "#{document&.document_key} #{version_label} (#{locale})"

    private

    def read_bytes
      case storage_backend
      when "database" then content.to_s
      when "resolver" then read_from_resolver
      when "active_storage" then read_from_active_storage
      end
    end

    def read_from_resolver
      resolver = Clickwrap.config.document_resolver

      unless resolver
        raise ConfigurationError,
              "Document version #{self} is stored through a resolver, but no " \
              "`document_resolver` is configured."
      end

      resolver.call(self).to_s
    end

    def read_from_active_storage
      unless defined?(::ActiveStorage)
        raise ConfigurationError,
              "Document version #{self} is stored in Active Storage, but Active Storage is " \
              "not loaded in this application."
      end

      ::ActiveStorage::Blob.find_signed!(storage_locator).download
    end

    def bare_digest(value)
      value.to_s.split(":").last
    end

    def refuse_to_change_published_version
      return unless published_at_was.present?

      changed_frozen = changed - %w[retired_at retired_reason]
      return if changed_frozen.empty? && !will_save_change_to_retired_at? && !will_save_change_to_retired_reason?

      raise DocumentVersionConflictError,
            "Document version #{self} has frozen published content. Use `retire!(because:)` to " \
            "record the named retirement metadata and stop future presentation, or publish a new " \
            "version; ordinary updates are refused."
    end

    def refuse_to_destroy_published_version
      return unless published?

      raise DocumentVersionConflictError,
            "Published document version #{self} cannot be destroyed because receipts may cite it."
    end
  end
end
