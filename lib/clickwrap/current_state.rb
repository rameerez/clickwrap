# frozen_string_literal: true

module Clickwrap
  # Projects retained event payloads onto the current-state table.
  #
  # Everything here is derived from retained event payloads. `rebuild_for!`
  # replays them while they still contain the affected statement identity. A
  # reviewed core disposition deliberately removes that identity, so rebuilding
  # through a disposed root would invent or silently lose state. The method
  # refuses first and leaves the existing projection untouched in that case.
  module CurrentState
    # `imported_legacy` projects like a capture: the source system says the act
    # happened, and a migrated application must keep answering "did this person
    # agree?" the way it answered the day before the migration — otherwise
    # every import ends in a mass forced re-acceptance, which is exactly the
    # history-rewriting an import exists to avoid. What stays different is the
    # evidence, not the answer: the event keeps `imported_provider`
    # attribution, its receipt names every unknown, and
    # `require_current_version` still sends people back when the documents
    # move on. (An exemption, by contrast, records that NO human acted — it
    # projects under its own state and never satisfies a human-action
    # predicate.)
    INITIAL_EVENT_TYPES = (Vocabulary::HUMAN_ACTION_EVENT_TYPES + %w[exemption imported_legacy]).freeze
    TRANSITION_STATE_BY_EVENT_TYPE = {
      "withdrawal" => "withdrawn",
      "supersession" => "superseded",
      "expiry" => "expired",
      "consumption" => "consumed",
      "revocation" => "revoked"
    }.freeze

    class << self
      # Applies one event to the projection. Runs inside the capture's
      # transaction, so a failure here rolls the capture back rather than
      # leaving evidence whose current state nobody can query.
      def apply!(event)
        return event unless INITIAL_EVENT_TYPES.include?(event.event_type)
        # An import quarantined with `counts_as_current: false` must stay
        # quarantined through every path — including a projection REBUILD.
        # Without this guard, `rebuild_for!` would launder consent the host
        # explicitly declined to honour into an active grant.
        return event unless projects_into_current_state?(event)

        StatementIdentityLock.acquire_for_actor!(event.actor_reference)
        identities = event.statements.map { |statement| identity_for(event, statement) }
        identities.sort_by { |identity| identity.fetch(:identity_digest) }.each do |identity|
          StatementIdentityLock.acquire!(identity.fetch(:identity_digest))
        end

        event.statements.each { |statement| apply_statement!(event, statement) }
      end

      def apply_statement!(event, statement)
        identity = identity_for(event, statement)

        loop do
          return StatementState.transaction(requires_new: true) do
            state = StatementState.find_or_initialize_by(identity)
            return state if candidate_is_not_newer?(state, event, statement)

            # A previous grant for the same identity is superseded rather
            # than overwritten. The projection moves on; the event that
            # recorded the earlier act stays exactly where it was.
            state.assign_attributes(
              kind: statement.kind,
              purpose_key: statement.purpose_key,
              actor_type: event.actor_type,
              actor_id: event.actor_id,
              subject_type: event.subject_type,
              subject_id: event.subject_id,
              subject_fingerprint: statement.subject_fingerprint,
              represented_party_reference: event.represented_party_reference.to_s,
              state: state_for(event, statement),
              current_action: statement.action,
              current_event_id: event.id,
              root_event_id: event.root_event_id || event.id,
              policy_revision_id: event.policy_revision_id,
              effective_at: effective_at_for(event, statement),
              expires_at: statement.expires_at,
              one_time: statement.one_time,
              document_version_ids: document_version_ids_for(event, statement)
            )

            apply_lifecycle_timestamps(state, event, statement)
            state.save!
            state
          end
        rescue ::ActiveRecord::RecordNotUnique
          # PostgreSQL marks a transaction failed after a uniqueness error.
          # The requires_new savepoint above absorbs that state before retry.
        end
      end

      # Marks a statement's projection with a lifecycle outcome, without
      # touching the event that produced it.
      def transition!(state, to:, event:, at: nil)
        at ||= Clickwrap.now

        StatementIdentityLock.acquire_for_actor!(state.actor_reference)
        StatementIdentityLock.acquire!(state.identity_digest)
        state = StatementState.lock.find(state.id)
        return state if event_is_not_newer?(state, event, effective_at: at)

        attributes = {
          state: to.to_s,
          current_event_id: event.id,
          current_action: event_action_for(to),
          effective_at: at
        }

        case to.to_s
        when "withdrawn" then attributes[:withdrawn_at] = at
        when "superseded" then attributes[:superseded_at] = at
        when "consumed" then attributes[:consumed_at] = at
        when "revoked" then attributes[:revoked_at] = at
        when "corrected" then attributes[:corrected_at] = at
        end

        state.update!(attributes)
      end

      # Rebuilds the projection for one actor from retained event payloads.
      # Refuses before deleting anything when an existing state depends on a
      # disposed root whose statement identity can no longer be reconstructed.
      def rebuild_for!(actor_reference:)
        StatementState.transaction do
          StatementIdentityLock.acquire_for_actor!(actor_reference)
          existing_states = StatementState.for_actor(actor_reference).lock.to_a
          ensure_rebuildable!(existing_states, actor_reference)
          StatementState.for_actor(actor_reference).delete_all

          Event.for_actor(actor_reference)
               .chronological
               .includes(:statements)
               .to_a
               .each { |event| replay!(event) }
        end
      end

      # Whether this event is allowed to shape the projection. Captures and
      # every other initial type always do; an `imported_legacy` event carries
      # its own answer in the structured provenance it was written with.
      # Imports that predate the flag project (they were written with exactly
      # that intent); only an explicit `counts_as_current: false` quarantines.
      def projects_into_current_state?(event)
        return true unless event.event_type == "imported_legacy"

        event.provider_verification.to_h["counts_as_current"] != false
      end

      private

      def identity_for(event, statement)
        StatementState.identity_for(
          policy_key: event.policy_key,
          statement_key: statement.statement_key,
          actor_reference: event.actor_reference,
          tenant_key: event.tenant_key,
          subject_key: event.subject_key,
          represented_party_reference: event.represented_party_reference
        )
      end

      def effective_at_for(event, statement)
        statement.valid_from || event.occurred_at || event.recorded_at_by_server
      end

      # Imports are commonly appended years after the act they describe. They
      # remain in history, but an older effective act must never resurrect a
      # grant that was withdrawn or superseded later. Server-recorded order and
      # durable sequence are deterministic tie-breakers only when effective
      # times are equal; they do not rewrite when the source says the act
      # happened.
      def candidate_is_not_newer?(state, event, statement)
        return false unless state.persisted?

        event_is_not_newer?(state, event, effective_at: effective_at_for(event, statement))
      end

      def event_is_not_newer?(state, event, effective_at:)
        current_event = state.current_event
        return false unless current_event
        return true if current_event.id.to_s == event.id.to_s

        candidate = [effective_at, event.recorded_at_by_server, event.recording_sequence.to_i, event.id.to_s]
        current = [state.effective_at, current_event.recorded_at_by_server,
                   current_event.recording_sequence.to_i, current_event.id.to_s]
        (candidate <=> current) <= 0
      end

      def ensure_rebuildable!(states, actor_reference)
        root_ids = states.map(&:root_event_id).compact.uniq
        disposed_root_id = Event.where(id: root_ids).where.not(core_event_disposed_at: nil).pick(:id)
        return unless disposed_root_id

        raise IntegrityCheckFailed,
              "Current state for #{actor_reference} depends on disposed root event #{disposed_root_id}. " \
              "Clickwrap refused to delete the existing projection because the reviewed disposition " \
              "removed the statement identity needed to rebuild it."
      end

      def replay!(event)
        return if event.disposed?
        unless event.digest_verified?
          raise IntegrityCheckFailed,
                "Event #{event.id} failed its digest during state rebuild."
        end

        if INITIAL_EVENT_TYPES.include?(event.event_type)
          apply!(event)
          return
        end

        destination = TRANSITION_STATE_BY_EVENT_TYPE[event.event_type]
        return unless destination

        root = Event.find_by(id: event.root_event_id)
        unless root&.digest_verified?
          raise IntegrityCheckFailed,
                "Lifecycle event #{event.id} does not have a verifiable root event, so its " \
                "statement identity cannot be rebuilt safely."
        end

        event.statements.each do |statement|
          identity = StatementState.identity_for(
            policy_key: event.policy_key,
            statement_key: statement.statement_key,
            # A withdrawal, expiry, consumption, or revocation may be appended
            # by a system/operator actor. That actor performed the lifecycle
            # transition; it is not the human whose statement is affected.
            # The immutable root event owns the statement identity.
            actor_reference: root.actor_reference,
            tenant_key: root.tenant_key,
            subject_key: root.subject_key,
            represented_party_reference: root.represented_party_reference
          )
          state = StatementState.find_by(identity)
          next unless state

          transition!(state, to: destination, event: event, at: statement.valid_from)
        end
      end

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

        state.effective_at = effective_at_for(event, statement)
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
