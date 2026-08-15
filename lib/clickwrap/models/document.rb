# frozen_string_literal: true

module Clickwrap
  # A logical document — `:terms`, `:privacy_notice` — separate from the
  # immutable versions that carry its actual bytes.
  class Document < ApplicationRecord
    self.table_name = "clickwrap_documents"

    has_many :versions,
             class_name: "Clickwrap::DocumentVersion",
             foreign_key: :document_id,
             inverse_of: :document,
             dependent: :restrict_with_error

    validates :key, presence: true, uniqueness: { scope: :tenant_key }

    scope :for_tenant, ->(tenant_key) { where(tenant_key: tenant_key.presence) }

    # The version a policy should present right now for a locale: published,
    # already effective, and not retired. A version scheduled for the future is
    # deliberately not presentable yet — that is what `effective_at` is for.
    def current_version(locale: I18n.locale, at: Clickwrap.now)
      versions
        .published
        .effective_at_or_before(at)
        .not_retired_at(at)
        .for_locale(locale)
        .order(effective_at: :desc, created_at: :desc)
        .first
    end

    def version(label, locale: I18n.locale)
      versions.for_locale(locale).find_by(version_label: label)
    end

    def to_s = key
  end
end
