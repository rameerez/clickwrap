# frozen_string_literal: true

module Clickwrap
  # One act inside one event: what was asserted, in the words actually shown,
  # and what the person did about it.
  #
  # `assertion_text` is the resolved sentence, not an I18n key. Storing the key
  # would be a false economy — its meaning can change in a later deploy, and
  # then the receipt no longer says what the person was asked.
  class EventStatement < ApplicationRecord
    self.table_name = "clickwrap_event_statements"
    self.record_timestamps = false

    belongs_to :event, class_name: "Clickwrap::Event", inverse_of: :statements

    has_many :event_documents,
             ->(statement) { where(statement_key: statement.statement_key) },
             class_name: "Clickwrap::EventDocument",
             foreign_key: :event_id,
             primary_key: :event_id,
             inverse_of: false,
             dependent: nil

    validates :statement_key, :assertion_text, :assertion_locale, presence: true
    validates :kind, inclusion: { in: Vocabulary::KINDS }
    validate :action_belongs_to_kind

    before_update :refuse_change
    before_destroy :refuse_destroy

    scope :of_kind, ->(kind) { where(kind: kind.to_s) }
    scope :answered, -> { where(answered: true) }

    def expired?(at = Clickwrap.now) = expires_at.present? && expires_at <= at

    # An optional control left unselected creates no grant. The receipt can show
    # that the option was offered and not taken, but it does not call silence an
    # affirmative refusal — those are different facts and only one of them
    # actually happened.
    def offered_and_not_taken? = optional? && !answered?

    def canonical_fragment
      {
        "statement" => statement_key,
        "kind" => kind,
        "action" => action,
        "assertion" => assertion_text,
        "locale" => assertion_locale,
        "required" => required?,
        "answered" => answered?,
        "answer" => answer.presence,
        "purpose" => purpose_key,
        "expires_at" => Receipt.format_time(expires_at),
        "one_time" => one_time? ? true : nil,
        "subject_fingerprint" => subject_fingerprint
      }.compact
    end

    def to_s = "#{kind} #{statement_key} (#{action})"

    private

    def action_belongs_to_kind
      return if kind.blank? || action.blank?
      return if Vocabulary::ACTIONS_FOR_KIND.fetch(kind, []).include?(action)

      errors.add(
        :action,
        "#{action.inspect} is not something a #{kind} can record. A #{kind} can be: " \
        "#{Vocabulary::ACTIONS_FOR_KIND.fetch(kind, []).join(', ')}."
      )
    end

    def refuse_change
      raise EventWriteFailed,
            "Statement #{statement_key} on event #{event_id} is an immutable snapshot of what " \
            "was shown and answered. Record a correction, withdrawal, or supersession instead."
    end

    def refuse_destroy
      raise EventWriteFailed,
            "Statement #{statement_key} on event #{event_id} cannot be destroyed."
    end
  end
end
