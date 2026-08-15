# frozen_string_literal: true

module Clickwrap
  module Retention
    # Applies a reviewed disposition plan.
    #
    #   result = Clickwrap::Retention::Applier.new(plan, applied_by: current_operator).call
    #   result.counts   # => {"applied" => 812, "skipped_held" => 4, ...}
    #
    # The plan said what would happen. This re-asks every question before it
    # does anything, because between the review and the run someone may have
    # placed a legal hold, changed a retention class, released a hold, deleted a
    # field by hand, or applied the plan already. When an item's answer has
    # changed, that item stops and is reported — the run never deletes a broader
    # set than the person who reviewed it agreed to, and never quietly deletes a
    # narrower one either.
    #
    # Each item is its own transaction: the deletion and the event that
    # documents it commit together, and a failure on item 900 does not undo the
    # 899 dispositions that already succeeded and were already recorded.
    class Applier
      # One line of the report. The same shape for every outcome, so a task, a
      # test, and a job all read it the same way, and `note` always says in a
      # sentence why the line is where it is.
      Outcome = Data.define(:part, :event_id, :record_id, :policy_key, :note) do
        def initialize(part:, event_id: nil, record_id: nil, policy_key: nil, note: nil)
          super
        end

        def to_report_entry
          {
            "part" => part.to_s,
            "event_id" => event_id,
            "record_id" => record_id&.to_s,
            "policy_key" => policy_key,
            "note" => note
          }.compact
        end
      end

      Result = Data.define(:applied, :skipped_held, :skipped_changed, :errors) do
        def counts
          {
            "applied" => applied.length,
            "skipped_held" => skipped_held.length,
            "skipped_changed" => skipped_changed.length,
            "errors" => errors.length
          }
        end

        def to_h
          {
            "applied" => applied.map(&:to_report_entry),
            "skipped_held" => skipped_held.map(&:to_report_entry),
            "skipped_changed" => skipped_changed.map(&:to_report_entry),
            "errors" => errors.map(&:to_report_entry),
            "counts" => counts
          }
        end

        def clean? = errors.empty?
      end

      def initialize(plan, applied_by:)
        @plan = plan
        @applied_by = applied_by
        @at = Clickwrap.now
        @applied = []
        @skipped_held = []
        @skipped_changed = []
        @errors = []
      end

      attr_reader :plan, :applied_by, :at

      def call
        # First, before anything is read or deleted: is this plan still one
        # somebody may act on? An expired, superseded, or already-applied plan
        # names a set that nobody currently agrees to.
        plan.ensure_usable!

        plan_items.each { |item| apply_item(item) }

        # The plan is single-use whether or not every item succeeded. A plan
        # that could be run twice would be a plan whose second run nobody
        # reviewed; the operator re-plans instead, and the fresh plan shows what
        # is still outstanding.
        plan.mark_applied!(by_reference: reference_for(applied_by))

        Result.new(applied: @applied, skipped_held: @skipped_held,
                   skipped_changed: @skipped_changed, errors: @errors)
      end

      private

      def plan_items
        Array(plan.scope.to_h["items"]).map { |entry| Planner::Item.from_plan_entry(entry) }
      end

      def apply_item(item)
        case item.part
        when :core_event then apply_core_event(item)
        when :ip_address, :browser_user_agent, :ip_geolocation then apply_annex_field(item)
        when :presentation then apply_presentation(item)
        else
          record_changed(item, "#{item.part} is not something this version of Clickwrap disposes of.")
        end
      rescue LegalHoldInEffect => error
        # Belt and braces: the hold was already checked above, so reaching here
        # means one was placed between the check and the write. The hold wins.
        record_held(item, error.message)
      rescue StandardError => error
        @errors << outcome_for(item, "#{error.class}: #{error.message}")
      end

      # --- The core event -------------------------------------------------------

      def apply_core_event(item)
        event = Event.find_by(id: item.event_id)
        return record_changed(item, "The event is no longer in the database.") if event.nil?
        return record_changed(item, "The core event was already disposed of.") if event.disposed?
        return record_held(item, hold_note(event)) if Disposition.legal_hold_in_effect?(event)

        eligibility = Planner.core_event_eligibility(event)
        return record_changed(item, not_due_note(eligibility)) unless still_disposable?(item, eligibility)

        Disposition.dispose_core_event!(event, because: reason)
        record_applied(item, "The core event was marked disposed of. The row and its history stay.")
      end

      # --- The optional request-evidence annex ----------------------------------

      def apply_annex_field(item)
        annex = RequestEvidence.find_by(id: item.record_id)
        return record_changed(item, "The request-evidence row is no longer in the database.") if annex.nil?

        event = annex.event
        return record_changed(item, "The event this evidence belonged to is gone.") if event.nil?
        return record_changed(item, "#{item.part} was already deleted.") if annex.deleted_for?(item.part)
        return record_held(item, hold_note(event)) if Disposition.legal_hold_in_effect?(event)

        eligibility = Planner.annex_eligibility(annex, item.part)
        return record_changed(item, not_due_note(eligibility)) unless still_disposable?(item, eligibility)

        deleted = Disposition.delete_field!(event, item.part, because: reason)
        return record_changed(item, "Nothing was recorded for #{item.part}, so nothing was deleted.") if deleted.nil?

        record_applied(item, "The recorded #{item.part} was deleted and the deletion was recorded.")
      end

      # --- Persisted presentations ---------------------------------------------

      def apply_presentation(item)
        presentation = Presentation.find_by(id: item.record_id)
        return record_changed(item, "The presentation is no longer in the database.") if presentation.nil?

        if presentation.events.exists?
          return record_changed(item, "An event now cites this presentation, so it is part of the evidence.")
        end

        due_at = presentation.retain_until || presentation.expires_at
        return record_changed(item, "This presentation is not past its retention date.") if due_at.nil? || due_at > at

        ::ActiveRecord::Base.transaction { presentation.destroy! }
        record_applied(item, "The unsubmitted presentation was deleted.")
      end

      # --- Re-checking ----------------------------------------------------------

      # A retention item must still be due under the rule as it stands right
      # now. An actor-request item is checked for holds and for still existing,
      # but not for retention: whether an erasure request outweighs a retention
      # duty is a decision a person made when they created and reviewed that
      # plan, and re-litigating it here would either ignore their decision or
      # pretend Clickwrap had made it.
      def still_disposable?(item, eligibility)
        return true if item.eligibility == "actor_request"

        eligibility.due?(at)
      end

      def not_due_note(eligibility)
        if eligibility.unresolved?
          "The rule no longer resolves to a date: #{eligibility.unresolved_reason}"
        else
          "The rule now says this is not due until #{Receipt.format_time(eligibility.eligible_at)}."
        end
      end

      def hold_note(event)
        "A legal hold is in effect for event #{event.id}, so nothing was deleted."
      end

      # --- Recording ------------------------------------------------------------

      def record_applied(item, note) = @applied << outcome_for(item, note)
      def record_held(item, note) = @skipped_held << outcome_for(item, note)
      def record_changed(item, note) = @skipped_changed << outcome_for(item, note)

      def outcome_for(item, note)
        Outcome.new(part: item.part, event_id: item.event_id, record_id: item.record_id,
                    policy_key: item.policy_key, note: note)
      end

      # The sentence that ends up on every disposition event this run appends.
      # It names the plan, so the deletion and the review that authorized it can
      # be read back together.
      def reason
        [sentence(plan.reason), "Applied disposition plan #{plan.id}."].compact.join(" ")
      end

      def sentence(text)
        trimmed = text.to_s.strip
        return nil if trimmed.empty?

        trimmed.end_with?(".", "!", "?") ? trimmed : "#{trimmed}."
      end

      def reference_for(actor)
        return nil if actor.nil?
        return actor if actor.is_a?(String)

        Clickwrap.config.identify_actor_with.call(actor)
      end
    end
  end
end
