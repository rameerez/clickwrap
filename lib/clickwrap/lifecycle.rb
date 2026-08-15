# frozen_string_literal: true

module Clickwrap
  # Everything that happens to evidence after it is captured.
  #
  # The rule that governs all of it: nothing here rewrites history. Withdrawing
  # consent, correcting a declaration, consuming an authorization, expiring an
  # acknowledgment, superseding an agreement — each appends a new event linked
  # to the one it acts on, and updates the current-state projection. The original
  # event stays exactly as it was written, because a receipt has to be able to
  # show both what is true now and what was true then.
  #
  # The lifecycle each kind gets is the one it actually needs. Consent is
  # withdrawable because someone must be able to change their mind as easily as
  # they agreed. An agreement is not: withdrawing future consent to marketing
  # does not retroactively unmake a contract, and a gem that let it would be
  # recording something false.
  module Lifecycle
    class << self
      # Withdraws a consent purpose. First-class, because consent that cannot be
      # withdrawn as easily as it was given is not what this gem will record as
      # consent — the policy compiler already refused to accept one without a
      # withdrawal route.
      def withdraw!(purpose_key, actor:, tenant: nil, subject: nil, because:, http_request: nil)
        require_reason!(because, "Withdrawing consent")

        states = StatementState
                 .for_actor(reference_for(actor))
                 .for_purpose(purpose_key)
                 .where(kind: "consent", state: "active")

        if states.empty?
          raise NotWithdrawableError,
                "There is no active consent for #{purpose_key.inspect} to withdraw. It may have " \
                "been withdrawn already, or never granted — leaving an optional control " \
                "unselected creates no grant."
        end

        events = states.map do |state|
          transition!(state, to: "withdrawn", event_type: "withdrawal", action: "withdrawn",
                      because: because, http_request: http_request, actor: actor)
        end

        events.length == 1 ? events.first : events
      end

      # Records a corrected factual statement. A correction does not imply the
      # original was false when it was made — people's circumstances change, and
      # conflating "this changed" with "this was a lie" would be both wrong and
      # unfair to the person who declared it.
      def correct!(statement_key, actor:, subject: nil, tenant: nil, replaces: nil,
                   because: nil, http_request: nil, submission: nil, answers: nil)
        state = find_state!(statement_key, actor: actor, subject: subject, tenant: tenant)

        unless Vocabulary.correctable?(state.kind)
          raise LifecycleError,
                "#{statement_key} is a #{state.kind}, which is not corrected. An agreement is " \
                "superseded by a new version; consent is withdrawn and granted again."
        end

        policy = Clickwrap.policy!(state.policy_key)

        ::ActiveRecord::Base.transaction do
          transition!(state, to: "corrected", event_type: "correction", action: "corrected",
                      because: because, http_request: http_request, actor: actor,
                      predecessor: replaces)

          Capture.new(policy: policy, actor: actor, subject: subject, tenant: tenant,
                      http_request: http_request, submission: submission, answers: answers,
                      reason: because).capture!
        end
      end

      # A renewal always starts a new validity period rather than extending the
      # old one, so a stale expiry can never quietly survive a renewal.
      def renew!(statement_key, actor:, subject: nil, tenant: nil, because: nil,
                 http_request: nil, submission: nil, answers: nil)
        state = find_state!(statement_key, actor: actor, subject: subject, tenant: tenant)
        policy = Clickwrap.policy!(state.policy_key)

        ::ActiveRecord::Base.transaction do
          Capture.new(policy: policy, actor: actor, subject: subject, tenant: tenant,
                      http_request: http_request, submission: submission, answers: answers,
                      reason: because).capture!
        end
      end

      def revoke!(statement_key, actor:, subject: nil, tenant: nil, because:, http_request: nil)
        require_reason!(because, "Revoking an authorization")

        state = find_state!(statement_key, actor: actor, subject: subject, tenant: tenant)

        transition!(state, to: "revoked", event_type: "revocation", action: "revoked",
                    because: because, http_request: http_request, actor: actor)
      end

      def supersede!(statement_key, actor:, subject: nil, tenant: nil, because: nil, http_request: nil)
        state = find_state!(statement_key, actor: actor, subject: subject, tenant: tenant)

        transition!(state, to: "superseded", event_type: "supersession", action: "superseded",
                    because: because, http_request: http_request, actor: actor)
      end

      # Consumes a one-time authorization. Called inside the transaction that
      # performs the protected action, after the row lock the capture took, so
      # two concurrent attempts cannot both spend the same authorization.
      def consume_authorization!(event:, because: nil)
        states = StatementState.where(current_event_id: event.id, one_time: true, state: "active")

        states.map do |state|
          state.lock!

          if state.consumed_at.present?
            raise AlreadyConsumedError,
                  "Authorization #{state.statement_key} was already consumed at " \
                  "#{state.consumed_at}. An authorization is not reusable merely because the " \
                  "agreement underneath it is still current."
          end

          transition!(state, to: "consumed", event_type: "consumption", action: "consumed",
                      because: because, actor: nil)
        end
      end

      # Expires everything past its validity. Reporting and tidiness only:
      # verification evaluates expiry live against the clock, so evidence never
      # becomes wrongly valid because a job did not run.
      def expire_due!(at: Clickwrap.now)
        StatementState.due_for_expiry(at).map do |state|
          transition!(state, to: "expired", event_type: "expiry", action: "expired",
                      because: "The validity period recorded at capture ended", actor: nil, at: at)
        end
      end

      # An explicitly recorded system exemption.
      #
      # Seeds, imports, invitations, admin actions, and service accounts must
      # never "accept" by omitting a browser parameter or by fabricating a human
      # click. An exemption says plainly that no human action occurred, records
      # who created it and why, and never satisfies `agreed_to?` — it answers
      # the separate `exempted_from?` question. There is no "missing checkbox
      # means system account" inference anywhere in this gem.
      def exempt!(policy_key, actor:, subject: nil, tenant: nil, because:)
        require_reason!(because, "Recording an exemption")

        policy = Clickwrap.policy!(policy_key.to_s)

        unless policy.permits_exemptions?
          raise LifecycleError,
                "Policy #{policy.key} does not permit exemptions. If system-created records " \
                "legitimately bypass it, say so in the policy with `permit_exemptions`, so the " \
                "decision is visible in review rather than implied by a call site."
        end

        now = Clickwrap.now
        revision = PolicyRevision.freeze_for(policy)

        ::ActiveRecord::Base.transaction do
          event = Event.create!(
            event_type: "exemption",
            policy_key: policy.key,
            policy_revision: revision,
            actor: actor.is_a?(::ActiveRecord::Base) ? actor : nil,
            actor_reference: reference_for(actor),
            tenant_key: tenant&.to_s,
            subject: subject.is_a?(::ActiveRecord::Base) ? subject : nil,
            subject_key: StatementState.subject_key_for(subject),
            capture_channel: "system",
            attribution_method: "system_process",
            recorded_at_by_server: now,
            reason: because,
            retention_class_key: policy.retention_class_key,
            canonical_schema_version: Clickwrap::CANONICAL_SCHEMA_VERSION,
            gem_version: Clickwrap::VERSION,
            created_at: now
          )

          policy.statements.each_with_index do |statement, index|
            event.statements.create!(
              ordinal: index,
              statement_key: statement.key,
              kind: statement.kind,
              action: statement.initial_action,
              assertion_text: "Exempted: no human action was recorded for this statement.",
              assertion_locale: "en",
              required: statement.required?,
              optional: statement.optional?,
              answered: false,
              purpose_key: statement.purpose_key,
              valid_from: now,
              created_at: now
            )
          end

          CurrentState.apply!(event.reload)
          event
        end
      end

      # Appends a linked lifecycle event without touching the projection. Used
      # by holds and dispositions, which record that something happened to the
      # evidence rather than changing what the evidence says.
      def append_lifecycle_event!(event:, event_type:, reason:, actor: nil, extra: {})
        now = Clickwrap.now

        Event.create!(
          {
            event_type: event_type,
            policy_key: event.policy_key,
            policy_revision_id: event.policy_revision_id,
            root_event_id: event.root_event_id || event.id,
            predecessor_event_id: event.id,
            actor: actor.is_a?(::ActiveRecord::Base) ? actor : nil,
            actor_reference: actor ? reference_for(actor) : event.actor_reference,
            tenant_key: event.tenant_key,
            subject_key: event.subject_key,
            capture_channel: "system",
            attribution_method: actor ? "operator_session" : "system_process",
            recorded_at_by_server: now,
            reason: reason,
            retention_class_key: event.retention_class_key,
            canonical_schema_version: Clickwrap::CANONICAL_SCHEMA_VERSION,
            gem_version: Clickwrap::VERSION,
            created_at: now
          }.merge(extra)
        )
      end

      private

      def transition!(state, to:, event_type:, action:, because:, actor:, http_request: nil,
                      predecessor: nil, at: nil)
        at ||= Clickwrap.now
        origin = Event.find_by(id: predecessor_id(predecessor) || state.current_event_id)

        ::ActiveRecord::Base.transaction do
          event = append_lifecycle_event!(
            event: origin,
            event_type: event_type,
            reason: because,
            actor: actor,
            extra: {
              http_request_id: http_request.respond_to?(:request_id) ? http_request.request_id : nil
            }.compact
          )

          event.statements.create!(
            ordinal: 0,
            statement_key: state.statement_key,
            kind: state.kind,
            action: action,
            assertion_text: lifecycle_assertion(action, state),
            assertion_locale: "en",
            required: false,
            optional: false,
            answered: false,
            purpose_key: state.purpose_key,
            valid_from: at,
            created_at: at
          )

          CurrentState.transition!(state, to: to, event: event, at: at)
          event
        end
      end

      def lifecycle_assertion(action, state)
        case action
        when "withdrawn" then "Consent for #{state.purpose_key} was withdrawn."
        when "corrected" then "The declaration #{state.statement_key} was corrected."
        when "revoked" then "The authorization #{state.statement_key} was revoked."
        when "consumed" then "The authorization #{state.statement_key} was consumed."
        when "expired" then "The validity period for #{state.statement_key} ended."
        when "superseded" then "#{state.statement_key} was superseded."
        else "#{state.statement_key} became #{action}."
        end
      end

      def predecessor_id(replaces)
        return nil if replaces.nil?
        return replaces if replaces.is_a?(String)
        return replaces.event_id if replaces.respond_to?(:event_id)

        replaces.id
      end

      def find_state!(statement_key, actor:, subject:, tenant:)
        state = StatementState
                .for_actor(reference_for(actor))
                .for_statement(statement_key)
                .where(subject_key: StatementState.subject_key_for(subject),
                       tenant_key: tenant.to_s)
                .first

        return state if state

        raise UnknownStatementError,
              "There is no recorded #{statement_key.inspect} for this actor and subject to act on."
      end

      def reference_for(actor)
        return nil if actor.nil?
        return actor if actor.is_a?(String)

        Clickwrap.config.identify_actor_with.call(actor)
      end

      def require_reason!(because, what)
        return unless because.to_s.strip.empty?

        raise LifecycleError,
              "#{what} needs a `because:` in plain English. It is stored on the event, and it is " \
              "the only thing that will explain this to someone reading the record later."
      end
    end
  end
end
