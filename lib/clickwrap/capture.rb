# frozen_string_literal: true

module Clickwrap
  # Turns a verified submission into an evidence event, and — when the caller
  # asks for it — commits that event in the same database transaction as the
  # action it authorizes.
  #
  # That last part is the whole point of the gem, so it is worth being exact
  # about what is promised.
  #
  # For a same-database protected action, `capture_and!` joins the caller's
  # transaction. If the evidence write fails, the block's work rolls back with
  # it. If the block raises, the event rolls back with it. Neither side can
  # commit alone, and there is no rescue-and-continue path anywhere in here: an
  # account that exists without the evidence that authorized it is precisely the
  # failure this class exists to make impossible.
  #
  # For anything crossing a system boundary — a payment provider, an identity
  # service, a remote signature — none of that applies, and pretending otherwise
  # would be worse than useless. Use `Clickwrap.authorize_external_action!` and
  # its outbox instead. This class will not claim atomicity it cannot deliver.
  class Capture
    # Internal control flow carrying the already-committed event for an
    # idempotent replay. It never escapes Capture's public API.
    class IdempotentReplay < StandardError
      attr_reader :event

      def initialize(event)
        @event = event
        super()
      end
    end
    private_constant :IdempotentReplay

    def initialize(policy:, actor: nil, subject: nil, tenant: nil, http_request: nil,
                   submission: nil, answers: nil, locale: nil, capture_channel: nil,
                   acting_for: nil, authentication_context: nil, attribution_method: nil,
                   idempotency_key: nil, prospective_actor: nil,
                   registration_flow_id: nil,
                   represented_party_creation_flow_id: nil,
                   consume_one_time_authorizations: true,
                   record_protected_outcome: true,
                   reason: nil, event_type: "capture", root_event_id: nil,
                   predecessor_event_id: nil, statement_action_overrides: {})
      @policy = policy
      @actor = actor
      @prospective_actor = prospective_actor
      @subject = subject
      @tenant = tenant
      @http_request = http_request
      @submission = submission
      @explicit_answers = answers
      @locale = locale
      @explicit_capture_channel = capture_channel&.to_s
      @capture_channel = @explicit_capture_channel
      @acting_for = acting_for
      @authentication_context = authentication_context
      @attribution_method = attribution_method
      @explicit_idempotency_key = idempotency_key
      @registration_flow_id = registration_flow_id
      @represented_party_creation_flow_id = represented_party_creation_flow_id
      @creating_represented_party = false
      @consume_one_time_authorizations = consume_one_time_authorizations
      @record_protected_outcome = record_protected_outcome == true
      @reason = reason
      @event_type = event_type.to_s
      @root_event_id = root_event_id
      @predecessor_event_id = predecessor_event_id
      @statement_action_overrides = statement_action_overrides.to_h.transform_keys(&:to_s)
    end

    attr_reader :policy, :actor, :subject, :tenant, :http_request, :submission, :capture_channel

    # Records evidence with no protected action attached.
    def capture!
      perform(protected_action: false) { |_pending| nil }
    end

    # Records evidence and runs the protected action inside the same
    # transaction. The block receives a read-only PendingReceipt whose stable
    # `event_id` the domain row can reference; export and verification are
    # unavailable on it until commit, because until commit there is nothing to
    # export.
    def capture_and!(&block)
      raise ArgumentError, "capture_and! needs a block containing the protected action" unless block

      perform(protected_action: true, &block)
    end

    # Signup. At first render there is no persisted actor, so the presentation
    # bound itself to a short-lived registration flow instead of to a fictional
    # authenticated user. Here the account is created and its stable reference
    # bound to the evidence, both inside one transaction, and the receipt records
    # `account_registration` attribution rather than claiming a session that did
    # not exist.
    def register!(&block)
      raise ArgumentError, "register! needs a block that persists the account" unless block

      @attribution_method = "account_registration"

      perform(protected_action: true) do |pending|
        result = block.call(pending)

        unless @prospective_actor&.persisted?
          raise RegistrationFailed,
                "The registration block did not persist the prospective actor. Use `save!`, or " \
                "raise when validation fails, so Clickwrap can roll the evidence back with it."
        end

        rebind_actor_after_registration!(pending)
        result
      end
    end

    # Creates the exact new record named by `represented_party:` and binds it
    # to the evidence before either can commit. Presentation records honestly
    # that membership authority was not yet verifiable; after the block saves
    # the record and creates its authority relationship, the adapter rereads
    # that relationship inside this same transaction and the finalized event
    # is rebound to the persisted represented party.
    def create_represented_party!(&block)
      unless block
        raise ArgumentError,
              "create_represented_party! needs a block that persists the represented party"
      end
      unless @acting_for.respond_to?(:new_record?) && @acting_for.new_record?
        raise RepresentedPartyCreationFailed,
              "create_represented_party! needs the exact new `represented_party:` record " \
              "that was used to render the presentation."
      end

      @creating_represented_party = true

      perform(protected_action: true) do |pending|
        result = block.call(pending)

        unless @acting_for.persisted?
          raise RepresentedPartyCreationFailed,
                "The represented-party creation block did not persist the exact represented party " \
                "whose type was bound at presentation. Save that record inside the block, create " \
                "its authority relationship there, and return the protected action result."
        end

        result
      end
    end

    private

    # Everything that can be checked without a transaction is checked without
    # one, and everything that must be resolved before the transaction opens is
    # resolved before it opens. A transaction that stays open across a network
    # call to a geolocation provider is a transaction holding locks on evidence
    # rows while waiting for someone else's DNS.
    def perform(protected_action:, &block)
      @protected_action = protected_action
      @joined_existing_transaction = ::ActiveRecord::Base.connection.transaction_open?
      replay_candidate = find_replay_candidate
      policy.validate_tenant!(tenant) unless replay_candidate
      verified = PresentationVerifier.new(
        policy: policy,
        submission: submission,
        explicit_answers: @explicit_answers,
        actor_reference: actor_reference,
        tenant_key: tenant_key,
        subject_key: subject_key,
        # The protected action may be the very thing that changes the bound
        # subject. An already-committed nonce is verified against its frozen
        # event below; recomputing the pre-action fingerprint first would make
        # a lost-response retry fail precisely because the first attempt worked.
        subject_fingerprint: (subject_fingerprint unless replay_candidate),
        represented_party: @acting_for,
        prospective_actor: @prospective_actor,
        registration_flow_id: @registration_flow_id,
        explicit_capture_channel: @explicit_capture_channel,
        represented_party_creation_flow_id: @represented_party_creation_flow_id,
        creating_represented_party: @creating_represented_party
      ).verify!(for_replay: replay_candidate.present?)
      manifest = verified.manifest
      revision = verified.revision
      answers = verified.answers
      @capture_channel = verified.capture_channel
      @frozen_statement_snapshots = verified.statement_snapshots
      @verified_document_versions_by_id = verified.document_versions_by_id
      @verified_manifest = manifest

      existing = replay_candidate || find_existing_event(idempotency_key_for(manifest))
      return replay(existing, answers, manifest) if existing

      request_evidence = resolve_request_evidence

      event = nil
      pending = nil

      begin
        run_in_transaction do
          verify_represented_party_authority! unless @creating_represented_party
          lock_statement_identities!(manifest)

          event = append_event!(manifest, revision, answers, request_evidence)
          pending = event.track_pending_receipt(
            PendingReceipt.new(event, wait_for_outer_transaction: @joined_existing_transaction)
          )

          @protected_action_result = block.call(pending)

          complete_represented_party_creation!(pending) if @creating_represented_party

          record_protected_outcome!(event)
          event.finalize_integrity!
          update_projections!(event)
          consume_one_time_authorizations!(event)
          mark_presentation_accepted!(manifest)
        end
      rescue IdempotentReplay => error
        return replay(error.event, answers, manifest)
      end

      # The after-commit hook is NOT invoked here. When this capture joined a
      # caller's transaction, "here" is still inside it, and a notification sent
      # from inside a transaction that later rolls back announces something that
      # never happened. The hook is registered as an `after_commit` callback on
      # the event instead, so Rails fires it on the real outermost commit.
      pending.committed? ? pending.receipt : pending
    end

    # Joins the caller's transaction when there is one. `requires_new: false` is
    # the whole guarantee: a host that already opened a transaction around its
    # domain work gets its evidence committed by the same COMMIT, not by a
    # nested one that could succeed while the outer one rolls back.
    def run_in_transaction(&)
      ::ActiveRecord::Base.transaction(requires_new: false, &)
    rescue ::ActiveRecord::Deadlocked, ::ActiveRecord::SerializationFailure => error
      raise RetryableTransactionError,
            "The capture hit a #{error.class.name.demodulize.underscore.humanize.downcase}. Clickwrap " \
            "does not retry automatically here because it cannot prove your protected action is " \
            "safe to run twice. Retry the whole operation if it is."
    end

    # --- Idempotency ----------------------------------------------------------

    # The presentation nonce is the idempotency key. It is server-generated,
    # issued once per render, and travels inside the signed token — so a
    # double-click, a retried request, and a replayed token all land on the same
    # key, and the unique index decides who wins.
    def idempotency_key_for(manifest)
      @explicit_idempotency_key || manifest.nonce
    end

    def find_existing_event(key)
      Event.find_by(policy_key: policy.key, idempotency_key: key)
    end

    # A signed manifest is safe to inspect before the full verification pass;
    # `Submission#manifest` has already verified its server signature. This
    # lookup authorizes no action. It only selects the stricter historical
    # replay path, whose context and exact answers are checked against the
    # committed event before a receipt is returned.
    def find_replay_candidate
      manifest = submission&.manifest
      key = @explicit_idempotency_key || manifest&.nonce
      key.present? ? find_existing_event(key) : nil
    end

    # A repeated identical submit returns the original receipt without running
    # the protected action again. A repeat with different answers is a replay
    # attempt, not a retry, and gets a stable failure rather than a second
    # event.
    def replay(event, answers, manifest)
      verify_replay_context!(event, manifest)

      recorded = event.statements.to_h { |statement| [statement.statement_key, statement.answer] }
      submitted = answers.transform_values { |value| value&.to_s }
      comparable = recorded.transform_values { |value| value&.to_s }

      unless comparable == submitted.slice(*comparable.keys)
        raise ReplayRejected,
              "This presentation was already used to record event #{event.id}, and the answers " \
              "submitted now differ from the ones recorded then. Render a new presentation."
      end

      Receipt.new(event)
    end

    def verify_replay_context!(event, manifest)
      expected_actor = manifest.registration_flow_id.present? ? event.actor_reference : actor_reference
      matches = event.policy_revision&.revision_digest == manifest.revision_digest &&
                event.presentation_manifest_digest == manifest.digest &&
                event.actor_reference == expected_actor &&
                event.tenant_key.to_s == tenant_key.to_s &&
                event.subject_key.to_s == subject_key.to_s &&
                event.subject_fingerprint.to_s == manifest.subject_fingerprint.to_s &&
                event.capture_channel == capture_channel &&
                replay_represented_party_matches?(event, manifest)

      return if matches && event.digest_verified?

      raise ReplayRejected,
            "This idempotency key was already used with a different actor, tenant, subject, " \
            "policy revision, presentation, or capture channel. Render a new presentation."
    end

    def replay_represented_party_matches?(event, manifest)
      if manifest.represented_party_will_be_created_by_protected_action?
        return event.represented_party_reference.present? &&
               event.authority_source.present? &&
               event.authority_role.present? &&
               event.authority_verified_at.present?
      end

      event.represented_party_reference.to_s == Reference.represented_party(@acting_for).to_s
    end

    # --- Locking --------------------------------------------------------------

    # A one-time authorization is consumed inside the transaction that uses it,
    # so the row is locked before anything else happens. Without this, two
    # concurrent submits could both read an unconsumed authorization and both
    # proceed — which for a withdrawal means two debits.
    def lock_statement_identities!(manifest)
      StatementIdentityLock.acquire_for_actor!(actor_reference)

      identities = @frozen_statement_snapshots.values.map do |statement|
        StatementState.identity_for(
          policy_key: policy.key,
          statement_key: statement["key"],
          actor_reference: actor_reference,
          tenant_key: tenant_key,
          subject_key: subject_key,
          represented_party_reference: represented_party_identity_reference
        )
      end

      identities.sort_by { |identity| identity.fetch(:identity_digest) }.each do |identity|
        StatementIdentityLock.acquire!(identity.fetch(:identity_digest))
        statement = @frozen_statement_snapshots.fetch(identity.fetch(:statement_key).to_s)
        verify_one_time_statement_is_available!(StatementState.find_by(identity), manifest) if statement["one_time"]
      end
    end

    def verify_one_time_statement_is_available!(state, manifest)
      return if state.nil? || !state.one_time?

      current_event = state.current_event
      presentation_is_newer = current_event && manifest.issued_at > current_event.recorded_at_by_server

      # A terminal authorization may be deliberately recreated only from a
      # presentation rendered after that terminal state existed. The outbox
      # path has one additional, equally deliberate case: a newer presentation
      # may supersede an authorization whose provider outcome is still pending.
      # That is how a host can abandon attempt A and create attempt B without a
      # late success for A ever consuming B. Distinct presentations rendered
      # before either write still serialize on the identity lock and the loser
      # is rejected, so this exception does not reopen the first-capture race.
      return if presentation_is_newer &&
                (!state.satisfies? || !@consume_one_time_authorizations)

      raise OneTimeAuthorizationConflict,
            "This presentation can no longer create a one-time authorization because " \
            "#{state.statement_key} is already #{state.state} for the same actor, tenant, subject, " \
            "and represented party. Recheck the protected action and render a new presentation " \
            "after the current authorization state is known."
    end

    # --- Writing --------------------------------------------------------------

    def append_event!(manifest, revision, answers, request_evidence)
      built = EventBuilder.new(
        policy: policy,
        manifest: manifest,
        revision: revision,
        statement_snapshots: @frozen_statement_snapshots,
        answers: answers,
        document_versions_by_id: @verified_document_versions_by_id,
        request_evidence: request_evidence,
        event_type: @event_type,
        root_event_id: @root_event_id,
        predecessor_event_id: @predecessor_event_id,
        actor: actor,
        actor_reference: actor_reference,
        actor_snapshot: actor_snapshot,
        represented_party: (@acting_for unless @creating_represented_party),
        authority_decision: @authority_decision,
        tenant_key: tenant_key,
        subject: subject,
        subject_key: subject_key,
        subject_fingerprint: subject_fingerprint,
        capture_channel: capture_channel,
        authentication_context: authentication_context,
        attribution_method: attribution_method,
        idempotency_key: idempotency_key_for(manifest),
        http_request_id: http_request_id,
        http_route_name: http_route_name,
        reason: @reason,
        statement_action_overrides: @statement_action_overrides
      ).build

      save_event_with_idempotency(built.event)
      attach_request_evidence(built.event, built.request_evidence_annex)
      built.event
    end

    # The unique index on (policy_key, idempotency_key) is the guarantee, not
    # this rescue — but the rescue has to run inside its own savepoint, because
    # PostgreSQL aborts the entire transaction on a unique violation and the
    # caller's domain work is in that transaction too.
    def save_event_with_idempotency(event)
      ::ActiveRecord::Base.transaction(requires_new: true) { event.save! }
    rescue ::ActiveRecord::RecordNotUnique
      existing = find_existing_event(event.idempotency_key)
      raise EventWriteFailed, "The evidence event could not be written." unless existing

      raise IdempotentReplay, existing
    end

    def attach_request_evidence(event, annex)
      return if annex.nil?

      annex.save!
      event.attach_request_evidence!(annex)
    end

    def resolve_request_evidence
      return nil if http_request.nil? && !policy.request_evidence.records_anything?

      RequestEvidenceExtractor.new(
        policy: policy,
        http_request: http_request,
        capture_channel: capture_channel
      ).extract
    end

    def verify_represented_party_authority!
      return if @acting_for.nil?

      decision = AuthorityVerifier.verify!(
        policy: policy,
        actor: actor,
        represented_party: @acting_for,
        tenant: tenant,
        authentication_context: authentication_context
      )
      details = decision.details.merge(
        "authority_at_presentation" => @verified_manifest.authority_at_presentation
      )
      details["represented_party_was_created_by_protected_action"] = true if
        @creating_represented_party
      @authority_decision = AuthorityDecision.new(
        authorized: true,
        source: decision.source,
        role: decision.role,
        verified_at: decision.verified_at,
        details: details
      )
    end

    def complete_represented_party_creation!(pending)
      verify_represented_party_authority!

      represented_party_type = if @acting_for.class.respond_to?(:polymorphic_name)
                                 @acting_for.class.polymorphic_name
                               else
                                 @acting_for.class.name
                               end
      pending.event.update_columns(
        represented_party_type: represented_party_type,
        represented_party_id: @acting_for.id,
        represented_party_reference: Reference.represented_party(@acting_for),
        authority_source: @authority_decision.source,
        authority_role: @authority_decision.role,
        authority_verified_at: @authority_decision.verified_at,
        authority_details: @authority_decision.details
      )
    end

    # --- After the write ------------------------------------------------------

    # An exact post-action reference is host-configured, never inferred. A block
    # that returned without raising tells us the block returned without raising;
    # it does not tell us what the host method meant, and guessing would put a
    # claim in a receipt that nobody made.
    def record_protected_outcome!(event)
      return unless @protected_action && @record_protected_outcome

      statement = policy.protected_outcome_statement
      return unless statement

      frozen = @frozen_statement_snapshots.fetch(statement.key)
      unless frozen["protected_outcome_version"] == statement.protected_outcome_version
        raise PresentationInvalid,
              "The protected-outcome recorder changed after this presentation was issued. " \
              "Re-render it against the current policy revision."
      end

      outcome = statement.record_protected_outcome_with.call(@protected_action_result)
      event.update_columns(protected_outcome: ProtectedOutcome.validate!(outcome))
    end

    def update_projections!(event)
      CurrentState.apply!(event)
    end

    def consume_one_time_authorizations!(event)
      return unless @protected_action && @consume_one_time_authorizations
      return unless event.statements.any?(&:one_time?)

      Lifecycle.consume_authorization!(event: event, because: "Consumed by the protected action")
    end

    def mark_presentation_accepted!(manifest)
      Presentation.find_by(nonce: manifest.nonce)&.mark_accepted!
    end

    def rebind_actor_after_registration!(pending)
      @actor = @prospective_actor
      @actor_reference = nil
      return if actor.nil? || !actor.persisted?

      pending.event.update_columns(
        actor_type: actor.class.name,
        actor_id: actor.id,
        actor_reference: actor_reference,
        actor_snapshot: actor_snapshot
      )
    end

    # --- Derived values -------------------------------------------------------

    def actor_reference
      @actor_reference ||= actor ? Reference.actor(actor) : "registration/#{@registration_flow_id}"
    end

    def actor_snapshot
      return {} if actor.nil?

      Clickwrap.config.snapshot_actor_with.call(actor) || {}
    end

    def tenant_key = Reference.tenant(tenant)

    def represented_party_identity_reference
      return "represented_party_creation/#{@represented_party_creation_flow_id}" if @creating_represented_party

      Reference.represented_party(@acting_for)
    end

    def subject_key = StatementState.subject_key_for(subject)

    def subject_fingerprint
      return @subject_fingerprint if defined?(@subject_fingerprint)

      @subject_fingerprint = SubjectFingerprint.for(policy, subject)
    end

    def authentication_context
      @authentication_context = (@authentication_context || {}).to_h.symbolize_keys
    end

    def attribution_method
      @attribution_method ||
        if actor.nil? && @prospective_actor
          "account_registration"
        elsif actor.is_a?(SystemActor) then "system_process"
        elsif actor.is_a?(AnonymousActor) then "anonymous_identifier"
        elsif authentication_context[:method].present? then "authenticated_session"
        else "unknown"
        end
    end

    def http_request_id
      return nil unless http_request.respond_to?(:request_id)

      http_request.request_id
    end

    def http_route_name
      return nil unless http_request.respond_to?(:path_parameters)

      controller = http_request.path_parameters[:controller]
      action = http_request.path_parameters[:action]
      [controller, action].compact.join("#").presence
    end
  end
end
