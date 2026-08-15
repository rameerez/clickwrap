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
    def initialize(policy:, actor: nil, subject: nil, tenant: nil, http_request: nil,
                   submission: nil, answers: nil, locale: nil, capture_channel: nil,
                   acting_for: nil, authentication_context: nil, attribution_method: nil,
                   idempotency_key: nil, prospective_actor: nil, client_reported_context: nil,
                   reason: nil)
      @policy = policy
      @actor = actor
      @prospective_actor = prospective_actor
      @subject = subject
      @tenant = tenant
      @http_request = http_request
      @submission = submission
      @explicit_answers = answers
      @locale = locale
      @capture_channel = (capture_channel || infer_capture_channel).to_s
      @acting_for = acting_for
      @authentication_context = authentication_context
      @attribution_method = attribution_method
      @explicit_idempotency_key = idempotency_key
      @client_reported_context = client_reported_context
      @reason = reason
    end

    attr_reader :policy, :actor, :subject, :tenant, :http_request, :submission, :capture_channel

    # Records evidence with no protected action attached.
    def capture!
      perform { |_pending| nil }
    end

    # Records evidence and runs the protected action inside the same
    # transaction. The block receives a read-only PendingReceipt whose stable
    # `event_id` the domain row can reference; export and verification are
    # unavailable on it until commit, because until commit there is nothing to
    # export.
    def capture_and!(&block)
      raise ArgumentError, "capture_and! needs a block containing the protected action" unless block

      perform(&block)
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

      perform do |pending|
        block.call(pending)
        rebind_actor_after_registration!(pending)
        nil
      end
    end

    private

    # Everything that can be checked without a transaction is checked without
    # one, and everything that must be resolved before the transaction opens is
    # resolved before it opens. A transaction that stays open across a network
    # call to a geolocation provider is a transaction holding locks on evidence
    # rows while waiting for someone else's DNS.
    def perform(&block)
      manifest = verify_presentation!
      revision = load_revision(manifest)
      answers = collect_answers(manifest)
      validate_answers!(manifest, answers)

      request_evidence = resolve_request_evidence

      existing = find_existing_event(idempotency_key_for(manifest))
      return replay(existing, answers) if existing

      event = nil

      run_in_transaction do
        lock_one_time_statements!

        event = append_event!(manifest, revision, answers, request_evidence)
        pending = PendingReceipt.new(event)

        block.call(pending)

        record_protected_outcome!(event)
        update_projections!(event)
        mark_presentation_accepted!(manifest)
      end

      # The after-commit hook is NOT invoked here. When this capture joined a
      # caller's transaction, "here" is still inside it, and a notification sent
      # from inside a transaction that later rolls back announces something that
      # never happened. The hook is registered as an `after_commit` callback on
      # the event instead, so Rails fires it on the real outermost commit.
      Receipt.new(event.reload)
    end

    # Joins the caller's transaction when there is one. `requires_new: false` is
    # the whole guarantee: a host that already opened a transaction around its
    # domain work gets its evidence committed by the same COMMIT, not by a
    # nested one that could succeed while the outer one rolls back.
    def run_in_transaction(&)
      ::ActiveRecord::Base.transaction(requires_new: false, &)
    rescue ::ActiveRecord::Deadlocked, ::ActiveRecord::SerializationFailure => e
      raise RetryableTransactionError,
            "The capture hit a #{e.class.name.demodulize.underscore.humanize.downcase}. Clickwrap " \
            "does not retry automatically here because it cannot prove your protected action is " \
            "safe to run twice. Retry the whole operation if it is."
    end

    # --- Presentation ---------------------------------------------------------

    def verify_presentation!
      manifest = submission&.manifest

      unless manifest
        raise PresentationInvalid,
              "This capture has no presentation. Render the policy with `form.clickwrap` or " \
              "`Clickwrap.present`, and submit the token it produced."
      end

      if manifest.policy_key != policy.key
        raise PresentationInvalid.new(
          "The submitted presentation is for policy #{manifest.policy_key.inspect}, " \
          "not #{policy.key.inspect}.",
          result: Verification::Result.failure(:presentation_policy_mismatch, policy_key: policy.key)
        )
      end

      if manifest.expired?
        raise PresentationExpired.new(
          "The presentation expired at #{manifest.expires_at}. Re-render the form so the person " \
          "acts on something current.",
          result: Verification::Result.failure(:presentation_expired, policy_key: policy.key)
        )
      end

      verify_bindings!(manifest)
      verify_document_digests!(manifest)

      manifest
    end

    # A token is bound to who it was issued to. Swapping in another account's
    # token, another tenant's, or another subject's is the attack this check
    # exists for, and each one gets its own stable error so a host can tell them
    # apart in logs.
    def verify_bindings!(manifest)
      if manifest.actor_reference.present? && actor_reference.present? &&
         manifest.actor_reference != actor_reference
        raise PresentationInvalid.new(
          "This presentation was issued to a different actor.",
          result: Verification::Result.failure(:presentation_actor_mismatch, policy_key: policy.key)
        )
      end

      if manifest.tenant_key.to_s != tenant_key.to_s
        raise PresentationInvalid.new(
          "This presentation was issued for a different tenant.",
          result: Verification::Result.failure(:presentation_tenant_mismatch, policy_key: policy.key)
        )
      end

      return unless manifest.subject_key.to_s != subject_key.to_s

      raise PresentationInvalid.new(
        "This presentation was issued for a different subject.",
        result: Verification::Result.failure(:presentation_subject_mismatch, policy_key: policy.key)
      )
    end

    # A deploy between GET and POST must never cause the server to record a
    # version the person was not offered. So the digests in the token are
    # checked against the rows now: if they still match, the presentation is
    # honored even though a newer version has published; if they do not, the
    # capture is refused and the host re-renders rather than silently recording
    # content nobody saw.
    def verify_document_digests!(manifest)
      manifest.statements.each do |statement|
        Array(statement["documents"]).each do |document|
          version = DocumentVersion.find_by(id: document["version_id"])

          # Two checks, not one. The recorded digest must still match what the
          # presentation offered, AND the stored bytes must still hash to that
          # digest — otherwise a version row edited in place would keep its
          # digest column and quietly pass, which is the exact substitution this
          # whole mechanism exists to prevent.
          next if version && Digest.secure_compare?(version.content_digest, document["digest"]) &&
                  version.verify_content_digest

          raise PresentationInvalid.new(
            "The document #{document['key']} version #{document['version']} no longer matches " \
            "what this presentation offered. Re-render the form so the person sees the current " \
            "version before acting on it.",
            result: Verification::Result.failure(
              :document_digest_mismatch, policy_key: policy.key,
              details: { "document" => document["key"] }
            )
          )
        end
      end
    end

    def load_revision(manifest)
      revision = PolicyRevision.find_by(policy_key: policy.key, revision_digest: manifest.revision_digest)

      unless revision
        raise PresentationInvalid.new(
          "The policy revision this presentation was issued under is no longer on file.",
          result: Verification::Result.failure(:stale_policy_revision, policy_key: policy.key)
        )
      end

      revision
    end

    # --- Answers --------------------------------------------------------------

    def collect_answers(manifest)
      return @explicit_answers.transform_keys(&:to_s) if @explicit_answers

      manifest.statements.to_h do |statement|
        [statement["key"], submission.answer_for(statement["key"])]
      end
    end

    def validate_answers!(manifest, answers)
      # Checked against what the CLIENT actually sent, not against what we
      # collected from the manifest — otherwise an unexpected key would be
      # quietly dropped during collection and the submission would look clean.
      # An attempt to answer a statement nobody offered is worth failing.
      submitted_keys = submission ? submission.answers.keys : answers.keys
      unknown = submitted_keys - manifest.statements.map { |statement| statement["key"] }

      unless unknown.empty?
        raise SubmissionInvalid,
              "The submission answers #{unknown.join(', ')}, which this presentation never " \
              "offered. Answers are only accepted for the statements the server declared."
      end

      policy.statements.each do |statement|
        value = answers[statement.key]
        validate_answer!(statement, value)
      end
    end

    def validate_answer!(statement, value)
      if statement.choices
        validate_choice!(statement, value)
      elsif statement.required? && !truthy?(value)
        raise AnswerInvalid.new(
          "#{statement.key} is required and was not answered.",
          statement_key: statement.key, reason: :missing_answer
        )
      end
    end

    def validate_choice!(statement, value)
      if value.blank?
        return unless statement.requires_an_explicit_choice? || statement.required?

        raise AnswerInvalid.new(
          "#{statement.key} needs an explicit choice; none was submitted.",
          statement_key: statement.key, reason: :missing_answer
        )
      end

      return if statement.choices.key?(value.to_s)

      raise AnswerInvalid.new(
        "#{value.inspect} is not one of the choices offered for #{statement.key} " \
        "(#{statement.choices.keys.join(', ')}).",
        statement_key: statement.key, reason: :missing_answer
      )
    end

    def truthy?(value)
      return false if value.nil?

      !%w[0 false off no].include?(value.to_s.downcase) && value.to_s != ""
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

    # A repeated identical submit returns the original receipt without running
    # the protected action again. A repeat with different answers is a replay
    # attempt, not a retry, and gets a stable failure rather than a second
    # event.
    def replay(event, answers)
      recorded = event.statements.to_h { |statement| [statement.statement_key, statement.answer] }
      submitted = answers.transform_values { |value| value.nil? ? nil : value.to_s }
      comparable = recorded.transform_values { |value| value.nil? ? nil : value.to_s }

      unless comparable == submitted.slice(*comparable.keys)
        raise ReplayRejected,
              "This presentation was already used to record event #{event.id}, and the answers " \
              "submitted now differ from the ones recorded then. Render a new presentation."
      end

      Receipt.new(event)
    end

    # --- Locking --------------------------------------------------------------

    # A one-time authorization is consumed inside the transaction that uses it,
    # so the row is locked before anything else happens. Without this, two
    # concurrent submits could both read an unconsumed authorization and both
    # proceed — which for a withdrawal means two debits.
    def lock_one_time_statements!
      return if policy.one_time_statements.empty?

      policy.one_time_statements.each do |statement|
        StatementState
          .lock
          .find_by(StatementState.identity_for(
                     policy_key: policy.key,
                     statement_key: statement.key,
                     actor_reference: actor_reference,
                     tenant_key: tenant_key,
                     subject_key: subject_key
                   ))
      end
    end

    # --- Writing --------------------------------------------------------------

    def append_event!(manifest, revision, answers, request_evidence)
      now = Clickwrap.now

      # The identifier is generated here rather than left to the model, because
      # the request-evidence annex is bound to it and that binding digest has to
      # be part of the event's canonical body BEFORE the event's own digest is
      # computed. Writing the binding afterwards would leave every event with
      # request evidence failing its own verification.
      event_id = Identifier.generate(now)
      annex = build_request_evidence(event_id, request_evidence)

      event = Event.new(
        id: event_id,
        request_evidence_digest: annex&.binding_digest,
        request_evidence_digest_algorithm: annex&.binding_digest_algorithm,
        request_evidence_key_id: annex&.binding_key_id,
        event_type: "capture",
        policy_key: policy.key,
        policy_revision: revision,
        actor: persisted_actor,
        actor_reference: actor_reference,
        actor_snapshot: actor_snapshot,
        represented_party: @acting_for.is_a?(::ActiveRecord::Base) ? @acting_for : nil,
        tenant_key: tenant_key.presence,
        subject: subject.is_a?(::ActiveRecord::Base) ? subject : nil,
        subject_key: subject_key,
        subject_fingerprint: subject_fingerprint,
        capture_channel: capture_channel,
        authentication_method: authentication_context[:method]&.to_s,
        authentication_context: authentication_context,
        attribution_method: attribution_method,
        recorded_at_by_server: now,
        idempotency_key: idempotency_key_for(manifest),
        http_request_id: http_request_id,
        presentation_manifest: manifest.to_h,
        presentation_manifest_digest: manifest.digest,
        retention_class_key: policy.retention_class_key,
        reason: @reason,
        canonical_schema_version: Clickwrap::CANONICAL_SCHEMA_VERSION,
        gem_version: Clickwrap::VERSION,
        application_version: Clickwrap.config.resolved_application_version,
        template_version: Clickwrap.config.resolved_template_version,
        created_at: now
      )

      build_statements(event, manifest, answers, now)
      build_documents(event, manifest)
      assign_retention(event)
      assign_chain_position(event)

      save_event_with_idempotency(event, answers)
      attach_request_evidence(event, annex)

      event
    end

    # The unique index on (policy_key, idempotency_key) is the guarantee, not
    # this rescue — but the rescue has to run inside its own savepoint, because
    # PostgreSQL aborts the entire transaction on a unique violation and the
    # caller's domain work is in that transaction too.
    def save_event_with_idempotency(event, answers)
      ::ActiveRecord::Base.transaction(requires_new: true) { event.save! }
    rescue ::ActiveRecord::RecordNotUnique
      existing = find_existing_event(event.idempotency_key)
      raise EventWriteFailed, "The evidence event could not be written." unless existing

      replay(existing, answers)
      raise ReplayRejected,
            "Another request recorded this presentation as event #{existing.id} while this one " \
            "was in flight. The protected action was not run twice."
    end

    def build_statements(event, manifest, answers, now)
      policy.statements.each_with_index do |statement, index|
        fragment = manifest.statement(statement.key) || {}
        answer = answers[statement.key]
        answered = statement.choices ? answer.present? : truthy?(answer)

        # An optional control left unselected creates no grant at all. The
        # receipt can show the option was offered and not taken, but silence is
        # not an affirmative refusal and this gem will not record it as one.
        next if statement.optional? && !answered

        event.statements.build(
          ordinal: index,
          statement_key: statement.key,
          kind: statement.kind,
          action: action_for(statement, answer, answered),
          assertion_text: fragment["assertion"],
          assertion_locale: manifest.locale,
          label_text: fragment["label"],
          link_labels: fragment["documents"]&.to_h { |d| [d["key"], d["label"]] } || {},
          choices: statement.choices,
          required: statement.required?,
          optional: statement.optional?,
          answer: answer,
          answered: answered,
          purpose_key: statement.purpose_key,
          withdrawal_path: statement.withdrawal_path,
          valid_from: now,
          expires_at: statement.expires_after(now),
          one_time: statement.one_time?,
          requires: statement.requires,
          subject_fingerprint: statement.subject_bound? ? subject_fingerprint : nil,
          created_at: now
        )
      end
    end

    def action_for(statement, answer, answered)
      return statement.initial_action unless statement.choices && answered

      meaning = statement.choices[answer.to_s]

      case meaning
      when "grant" then statement.initial_action
      when "decline" then "declined"
      else meaning
      end
    end

    def build_documents(event, manifest)
      ordinal = 0

      manifest.statements.each do |statement|
        Array(statement["documents"]).each do |document|
          version = DocumentVersion.find_by(id: document["version_id"])

          event.documents.build(
            statement_key: statement["key"],
            document_key: document["key"],
            document_version_id: version&.id,
            version_label: document["version"],
            locale: document["locale"],
            media_type: document["media_type"],
            content_digest: document["digest"],
            rendered_content_digest: version&.rendered_content_digest,
            ordinal: ordinal,
            created_at: event.recorded_at_by_server
          )

          ordinal += 1
        end
      end
    end

    def assign_retention(event)
      return if policy.retention_class_key.nil?

      retention = Clickwrap.retention_class!(policy.retention_class_key)
      rule = retention.rule_for(:core_event)
      return if rule.nil?

      if rule.duration?
        event.retain_core_event_until = event.recorded_at_by_server + rule.duration
      else
        event.retention_rule_name = rule.host_event_name.to_s
      end
    end

    # Chaining is off unless configured. When it is on, the scope is per tenant
    # or per policy aggregate, never one global chain: a single chain across
    # unrelated tenants makes every capture queue behind every other one.
    def assign_chain_position(event)
      return unless Clickwrap.config.chain_event_history_with

      scope = [tenant_key.presence || "global", policy.key].join("/")
      previous_digest, sequence = ChainHead.append!(
        chain_scope: scope,
        event_id: event.id || Identifier.generate,
        event_digest: nil
      )

      event.chain_scope = scope
      event.chain_sequence = sequence
      event.previous_event_digest = previous_digest
    end

    # Builds the annex record in memory, so its binding digest can go into the
    # event's canonical body before that body is digested. Nothing is written
    # here; the row is saved once the event exists to hang it from.
    def build_request_evidence(event_id, resolved)
      return nil if resolved.nil? || !resolved.records_anything?

      RequestEvidence.new(
        resolved.attributes.merge(event_id: event_id, created_at: Clickwrap.now)
      )
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

    # --- After the write ------------------------------------------------------

    # An exact post-action reference is host-configured, never inferred. A block
    # that returned without raising tells us the block returned without raising;
    # it does not tell us what the host method meant, and guessing would put a
    # claim in a receipt that nobody made.
    def record_protected_outcome!(event)
      statement = policy.statements.find(&:record_protected_outcome_with)
      return unless statement && subject

      outcome = statement.record_protected_outcome_with.call(subject)
      return if outcome.nil?

      event.update_columns(protected_outcome: outcome.deep_stringify_keys) # rubocop:disable Rails/SkipsModelValidations
    end

    def update_projections!(event)
      CurrentState.apply!(event)
    end

    def mark_presentation_accepted!(manifest)
      Presentation.find_by(nonce: manifest.nonce)&.mark_accepted!
    end

    def rebind_actor_after_registration!(pending)
      @actor = @prospective_actor
      return if actor.nil?

      pending.event.update_columns( # rubocop:disable Rails/SkipsModelValidations
        actor_type: actor.class.name,
        actor_id: actor.id,
        actor_reference: actor_reference
      )
    end

    # --- Derived values -------------------------------------------------------

    def persisted_actor = actor.is_a?(::ActiveRecord::Base) ? actor : nil

    def actor_reference
      @actor_reference ||=
        if actor
          Clickwrap.config.identify_actor_with.call(actor)
        elsif @prospective_actor
          "pending_registration"
        end
    end

    def actor_snapshot
      return {} if actor.nil?

      Clickwrap.config.snapshot_actor_with.call(actor) || {}
    end

    def tenant_key
      return "" if tenant.nil?
      return tenant.to_s if tenant.is_a?(String) || tenant.is_a?(Symbol)
      return tenant.to_gid.to_s if tenant.respond_to?(:to_gid)

      "#{tenant.class.name}/#{tenant.id}"
    end

    def subject_key = StatementState.subject_key_for(subject)

    def subject_fingerprint
      return @subject_fingerprint if defined?(@subject_fingerprint)

      statement = policy.statements.find(&:subject_bound?)
      @subject_fingerprint =
        if statement && subject
          value = statement.subject_fingerprint_with.call(subject)
          value.nil? ? nil : Digest.digest(value.to_s)
        end
    end

    def authentication_context
      @resolved_authentication_context ||= (@authentication_context || {}).to_h.symbolize_keys
    end

    def attribution_method
      @attribution_method ||
        if actor.nil? && @prospective_actor then "account_registration"
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

    def infer_capture_channel
      http_request ? "web_browser" : "background_job"
    end
  end
end
