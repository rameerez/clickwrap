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
  # "this Markdown file existed" from "this rendered HTML was on screen" instead
  # of letting one claim borrow the other's credibility.
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
    before_update :refuse_to_change_published_content

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
      rendered_content.presence || content_bytes
    end

    def prefixed_content_digest = content_digest

    def to_s = "#{document&.key} #{version_label} (#{locale})"

    def to_receipt_fragment
      {
        "key" => document&.key,
        "version" => version_label,
        "locale" => locale,
        "media_type" => media_type,
        content_digest_algorithm => bare_digest(content_digest)
      }.tap do |fragment|
        if rendered_content_digest
          fragment["rendered_#{content_digest_algorithm}"] =
            bare_digest(rendered_content_digest)
        end
      end
    end

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

    def refuse_to_change_published_content
      return unless published_at_was.present?

      frozen_columns = %w[content content_digest content_digest_algorithm version_label locale
                          rendered_content rendered_content_digest]
      changed_frozen = changed & frozen_columns
      return if changed_frozen.empty?

      raise DocumentVersionConflictError,
            "Document version #{self} is published, so #{changed_frozen.join(", ")} cannot " \
            "change. Publish a new version instead — receipts already point at this one, and " \
            "editing it would silently change what they say the person was shown."
    end
  end
end
