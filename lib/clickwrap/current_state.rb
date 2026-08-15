# frozen_string_literal: true

module Clickwrap
  # Projects immutable events onto the current-state table.
  #
  # Everything here is derived. If `clickwrap_statement_states` were dropped
  # entirely it could be rebuilt from `clickwrap_events`, and `rebuild_for!`
  # does exactly that. Keeping the projection strictly downstream of the events
  # is what lets it be mutable and fast without any of that leaking into the
  # record of what actually happened.
  module CurrentState
    class << self
      # Applies one event to the projection. Runs inside the capture's
      # transaction, so a failure here rolls the capture back rather than
      # leaving evidence whose current state nobody can query.
      def apply!(event)
        event.statements.each { |statement| apply_statement!(event, statement) }
      end

      def apply_statement!(event, statement)
        identity = StatementState.identity_for(
          policy_key: event.policy_key,
          statement_key: statement.statement_key,
          actor_reference: event.actor_reference,
          tenant_key: event.tenant_key,
          subject_key: event.subject_key
        )

        state = StatementState.find_or_initialize_by(identity)

        # A previous grant for the same identity is superseded rather than
        # overwritten. The projection moves on; the event that recorded the
        # earlier act stays exactly where it was.
        state.assign_attributes(
          kind: statement.kind,
          purpose_key: statement.purpose_key,
          actor_type: event.actor_type,
          actor_id: event.actor_id,
          subject_type: event.subject_type,
          subject_id: event.subject_id,
          subject_fingerprint: statement.subject_fingerprint,
          state: state_for(event, statement),
          current_action: statement.action,
          current_event_id: event.id,
          root_event_id: event.root_event_id || event.id,
          policy_revision_id: event.policy_revision_id,
          effective_at: statement.valid_from || event.recorded_at_by_server,
          expires_at: statement.expires_at,
          one_time: statement.one_time,
          document_version_ids: document_version_ids_for(event, statement)
        )

        apply_lifecycle_timestamps(state, event, statement)

        state.save!
        state
      rescue ::ActiveRecord::RecordNotUnique
        # Two concurrent captures for the same identity: the unique index did
        # its job. Re-read and let the second one apply on top of the first.
        retry
      end

      # Marks a statement's projection with a lifecycle outcome, without
      # touching the event that produced it.
      def transition!(state, to:, event:, at: nil)
        at ||= Clickwrap.now

        attributes = { state: to.to_s, current_event_id: event.id, current_action: event_action_for(to) }

        case to.to_s
        when "withdrawn" then attributes[:withdrawn_at] = at
        when "superseded" then attributes[:superseded_at] = at
        when "consumed" then attributes[:consumed_at] = at
        when "revoked" then attributes[:revoked_at] = at
        when "corrected" then attributes[:corrected_at] = at
        end

        state.update!(attributes)
      end

      # Expires everything whose validity has run out. This is a convenience for
      # reporting and for keeping the projection tidy; verification does not
      # depend on it having run, because expiry is evaluated live against the
      # clock rather than trusted from a column a job may not have reached yet.
      def expire_due!(at: Clickwrap.now)
        StatementState.due_for_expiry(at).find_each do |state|
          state.update!(state: "expired")
        end
      end

      # Rebuilds the projection for one actor from their events. Useful after a
      # restore, after a bug, or to prove that the projection really is derived.
      def rebuild_for!(actor_reference:)
        StatementState.for_actor(actor_reference).delete_all

        Event.for_actor(actor_reference)
             .where(event_type: Vocabulary::HUMAN_ACTION_EVENT_TYPES)
             .chronological
             .includes(:statements)
             .find_each { |event| apply!(event) }
      end

      private

      def state_for(event, statement)
        return "exempted" if event.event_type == "exemption"
        return "declined" if statement.action == "declined"

        "active"
      end

      def apply_lifecycle_timestamps(state, event, statement)
        return unless state.persisted?

        # A renewal starts a fresh validity period rather than extending the old
        # one, so the previous expiry never quietly survives.
        return unless statement.action == "renewed"

        state.effective_at = event.recorded_at_by_server
        state.withdrawn_at = nil
        state.expires_at = statement.expires_at
      end

      def event_action_for(state_name)
        case state_name.to_s
        when "withdrawn" then "withdrawn"
        when "superseded" then "superseded"
        when "consumed" then "consumed"
        when "revoked" then "revoked"
        when "corrected" then "corrected"
        when "expired" then "expired"
        else state_name.to_s
        end
      end

      def document_version_ids_for(event, statement)
        event.documents
             .select { |document| document.statement_key == statement.statement_key }
             .map { |document| document.document_version_id.to_s }
      end
    end
  end
end
