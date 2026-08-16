# frozen_string_literal: true

module Clickwrap
  # Answers "does this actor currently satisfy this policy?" and, when the
  # answer is no, exactly why.
  #
  # The convention across the whole gem is consistent: predicates answer
  # booleans, `verify` returns a Result, and bang methods raise a typed error
  # carrying that same Result. An application should never have to parse an
  # English message to make an authorization decision, so the reason is always
  # one of the stable symbols in Clickwrap::Vocabulary::VERIFICATION_ERRORS and
  # the human sentence is localized separately.
  module Verification
    UNSPECIFIED = Object.new.freeze

    # The structured answer. `details` carries stable machine-readable facts —
    # never a surprise field of personal data, because a verification result
    # routinely ends up in a log line or an API response.
    class Result
      attr_reader :error, :policy_key, :statement_key, :event_id, :details

      def initialize(success:, error: nil, policy_key: nil, statement_key: nil,
                     event_id: nil, details: {})
        @success = success
        @error = error
        @policy_key = policy_key
        @statement_key = statement_key
        @event_id = event_id
        @details = details.freeze
        freeze
      end

      def self.success(policy_key:, event_id: nil, details: {})
        new(success: true, policy_key: policy_key, event_id: event_id, details: details)
      end

      # Whether this result's evidence was recorded after another's. Event ids
      # are ULIDs, so lexicographic order IS creation order — this makes that
      # guarantee API instead of folklore, for multi-step flows that require
      # one act to follow another ("the declaration must come after the
      # acknowledgments"):
      #
      #   declaration.recorded_after?(acknowledgments)  # => true or false
      #
      # Accepts another verification result or a bare event id. False whenever
      # either side has no event, which composes with `success?` the way a
      # guard should: nothing about a missing act is "after" anything.
      def recorded_after?(other)
        other_event_id = other.respond_to?(:event_id) ? other.event_id : other

        event_id.present? && other_event_id.present? && event_id.to_s > other_event_id.to_s
      end

      # One predicate per stable error symbol, generated from the vocabulary so
      # the two can never drift: `result.subject_fingerprint_mismatch?`,
      # `result.no_evidence?`, `result.consent_withdrawn?`, … Branching on a
      # predicate reads aloud and survives typos (a misspelled predicate is
      # NoMethodError; a misspelled symbol comparison is silently false).
      Vocabulary::VERIFICATION_ERRORS.each do |error_symbol|
        define_method("#{error_symbol}?") { error == error_symbol }
      end

      def self.failure(error, policy_key: nil, statement_key: nil, event_id: nil, details: {})
        unless Vocabulary::VERIFICATION_ERRORS.include?(error)
          raise ArgumentError,
                "#{error.inspect} is not a stable verification error. Add it to " \
                "Clickwrap::Vocabulary::VERIFICATION_ERRORS so applications can branch on it."
        end

        new(success: false, error: error, policy_key: policy_key, statement_key: statement_key,
            event_id: event_id, details: details)
      end

      def success? = @success
      def failure? = !@success

      def message
        return I18n.t("clickwrap.verification.success", default: "Verified.") if success?

        I18n.t(
          "clickwrap.verification.errors.#{error}",
          policy: policy_key,
          statement: statement_key,
          default: default_message
        )
      end

      def to_h
        {
          "success" => success?,
          "policy" => policy_key,
          "statement" => statement_key,
          "error" => error&.to_s,
          "event_id" => event_id,
          "details" => details
        }.compact
      end

      def as_json(*) = to_h

      def inspect
        success? ? "#<Clickwrap::Verification::Result success>" : "#<Clickwrap::Verification::Result #{error}>"
      end

      private

      def default_message
        error.to_s.tr("_", " ").capitalize
      end
    end

    class << self
      # Verifies a policy for an actor, or re-verifies one specific recorded
      # event. Both are the same question asked from different ends: the first
      # is "is there current evidence", the second is "is this evidence still
      # good for this exact operation".
      def verify(policy_or_event, actor: nil, subject: nil, tenant: nil, acting_for: UNSPECIFIED,
                 policy: nil, at: nil, require_current_revision: false)
        at ||= Clickwrap.now

        if policy_or_event.is_a?(String) && Identifier.valid?(policy_or_event)
          verify_event(policy_or_event, policy: policy, subject: subject,
                                        acting_for: acting_for, at: at)
        else
          acting_for = nil if acting_for.equal?(UNSPECIFIED)
          verify_policy(policy_or_event, actor: actor, subject: subject, tenant: tenant,
                                         acting_for: acting_for, at: at,
                                         require_current_revision: require_current_revision)
        end
      end

      private

      def verify_policy(policy_key, actor:, subject:, tenant:, acting_for:, at:,
                        require_current_revision: false)
        policy = Clickwrap.policies[policy_key.to_s]

        return Result.failure(:unknown_policy, policy_key: policy_key.to_s) unless policy

        actor_reference = reference_for(actor)

        return Result.failure(:wrong_actor, policy_key: policy.key) unless actor_reference

        states = load_states(policy, actor_reference, tenant, subject, acting_for)
        # Resolved once, only when asked for: "was this act made under the
        # wording that is current NOW?" A bumped statement compiles a new
        # revision, so evidence recorded under a superseded one re-asks — the
        # verify-time counterpart of the capture-time :stale_policy_revision.
        current_revision_id = (PolicyRevision.freeze_for(policy).id if require_current_revision)

        policy.required_statements.each do |statement|
          state = states[statement.key]

          return Result.failure(:no_evidence, policy_key: policy.key, statement_key: statement.key) unless state

          source_failure = check_state_source(policy, statement, state)
          return source_failure if source_failure

          failure = check_statement(policy, statement, state, subject, at)
          return failure if failure

          if current_revision_id && state.policy_revision_id != current_revision_id
            return Result.failure(:stale_policy_revision, policy_key: policy.key,
                                                          statement_key: statement.key,
                                                          event_id: state.current_event_id)
          end
        end

        newest = states.values.max_by(&:effective_at)
        Result.success(policy_key: policy.key, event_id: newest&.current_event_id,
                       details: { "statements" => states.keys.sort })
      end

      def check_statement(policy, statement, state, subject, at)
        unless state.satisfies?(at)
          return Result.failure(state.failure_reason(at),
                                policy_key: policy.key,
                                statement_key: statement.key,
                                event_id: state.current_event_id)
        end

        if statement.subject_bound?
          expected = subject_fingerprint_for(statement, subject)

          if expected.nil?
            return Result.failure(:wrong_subject, policy_key: policy.key,
                                                  statement_key: statement.key,
                                                  event_id: state.current_event_id)
          end

          unless Digest.secure_compare?(expected, state.subject_fingerprint.to_s)
            return Result.failure(:subject_fingerprint_mismatch,
                                  policy_key: policy.key,
                                  statement_key: statement.key,
                                  event_id: state.current_event_id)
          end
        end

        if statement.requires_current_version?
          stale = stale_document?(statement, state)

          if stale
            return Result.failure(:unseen_document_version,
                                  policy_key: policy.key,
                                  statement_key: statement.key,
                                  event_id: state.current_event_id,
                                  details: { "document" => stale })
          end
        end

        # An authorization's prerequisites must have been made in the same
        # submission, and before it. A fresh acknowledgment paired with a
        # year-old declaration is not the evidence the policy asked for.
        statement.requires.each do |prerequisite_key|
          prerequisite = Event.where(id: state.root_event_id)
                              .joins(:statements)
                              .where(clickwrap_event_statements: { statement_key: prerequisite_key })
                              .exists?

          next if prerequisite

          return Result.failure(:predecessor_missing, policy_key: policy.key,
                                                      statement_key: statement.key, event_id: state.current_event_id,
                                                      details: { "requires" => prerequisite_key })
        end

        nil
      end

      def check_state_source(policy, statement, state)
        event = Event.includes(:statements, documents: :document_version).find_by(id: state.current_event_id)
        unless event
          return Result.failure(:no_evidence, policy_key: policy.key,
                                              statement_key: statement.key)
        end

        if event.disposed?
          if event.documented_core_disposition?
            return Result.failure(:core_event_disposed, policy_key: policy.key,
                                                        statement_key: statement.key,
                                                        event_id: event.id)
          end

          return Result.failure(:integrity_check_failed, policy_key: policy.key,
                                                         statement_key: statement.key,
                                                         event_id: event.id,
                                                         details: { "disposition" => "not_documented" })
        end

        unless event.evidence_integrity_verified?
          return Result.failure(:integrity_check_failed, policy_key: policy.key,
                                                         statement_key: statement.key,
                                                         event_id: event.id,
                                                         details: {
                                                           "request_evidence_binding" =>
                                                             event.request_evidence_binding_status.to_s
                                                         })
        end

        recorded = event.statement(statement.key)
        identity_source = statement_identity_source(event, state)
        identity_matches = identity_source &&
                           event.policy_key == policy.key &&
                           identity_source.policy_key == policy.key &&
                           identity_source.actor_reference == state.actor_reference &&
                           identity_source.tenant_key.to_s == state.tenant_key.to_s &&
                           identity_source.subject_key.to_s == state.subject_key.to_s &&
                           identity_source.represented_party_reference.to_s ==
                           state.represented_party_reference.to_s &&
                           recorded&.kind == statement.kind &&
                           recorded&.action == state.current_action

        unless identity_matches
          return Result.failure(:integrity_check_failed, policy_key: policy.key,
                                                         statement_key: statement.key,
                                                         event_id: event.id)
        end

        # An active grant needs a source that can legitimately grant: a human
        # action this application captured, or a legacy record imported with
        # its provenance. An exemption or a lifecycle event backing an
        # "active" projection is a hand-crafted row, and stays refused.
        active_grant_source = event.human_action? || event.event_type == "imported_legacy"
        if state.state == "active" && !active_grant_source
          return Result.failure(:no_evidence, policy_key: policy.key,
                                              statement_key: statement.key,
                                              event_id: event.id)
        end

        mismatched = event.documents.any? do |binding|
          !binding.still_matches_stored_version? ||
            !binding.document_version&.verify_content_digest ||
            !binding.document_version&.verify_rendered_content_digest
        end

        return unless mismatched

        Result.failure(:document_digest_mismatch, policy_key: policy.key,
                                                  statement_key: statement.key,
                                                  event_id: event.id)
      end

      # Lifecycle events record who performed the transition. For an automatic
      # expiry/consumption that is a system actor; for an administrative
      # revocation it may be an operator. Neither replaces the human whose
      # statement is being changed. Its immutable root event is therefore the
      # source of actor/tenant/subject identity, while the current event is the
      # source of the transition action itself.
      def statement_identity_source(event, state)
        return event if CurrentState::INITIAL_EVENT_TYPES.include?(event.event_type)
        return nil unless CurrentState::TRANSITION_STATE_BY_EVENT_TYPE.key?(event.event_type)
        return nil unless event.root_event_id.to_s == state.root_event_id.to_s

        root = Event.find_by(id: event.root_event_id)
        predecessor = Event.find_by(id: event.predecessor_event_id)
        return nil unless root&.digest_verified? && predecessor&.digest_verified?
        return nil unless (predecessor.root_event_id.presence || predecessor.id).to_s == root.id.to_s

        root
      end

      def verify_event(event_id, policy:, subject:, acting_for:, at:)
        event = Event.find_by(id: event_id)

        return Result.failure(:no_evidence, event_id: event_id) unless event

        if policy && event.policy_key != policy.to_s
          return Result.failure(:presentation_policy_mismatch, policy_key: event.policy_key,
                                                               event_id: event.id)
        end

        if event.disposed?
          if event.documented_core_disposition?
            return Result.failure(:core_event_disposed, policy_key: event.policy_key, event_id: event.id)
          end

          return Result.failure(
            :integrity_check_failed,
            policy_key: event.policy_key,
            event_id: event.id,
            details: { "disposition" => "not_documented" }
          )
        end

        unless event.evidence_integrity_verified?
          return Result.failure(
            :integrity_check_failed,
            policy_key: event.policy_key,
            event_id: event.id,
            details: { "request_evidence_binding" => event.request_evidence_binding_status.to_s }
          )
        end

        # Two different ways a document can stop matching, and both have to be
        # caught. The first is the version row being swapped or its recorded
        # digest changed. The second is subtler and more likely: the row keeps
        # its digest column while someone edits the bytes underneath it, which
        # would leave every receipt citing it silently describing content that
        # is no longer there. So the stored bytes get re-digested, not trusted.
        mismatched = event.documents.reject do |binding|
          binding.still_matches_stored_version? &&
            binding.document_version&.verify_content_digest &&
            binding.document_version.verify_rendered_content_digest
        end

        unless mismatched.empty?
          return Result.failure(:document_digest_mismatch, policy_key: event.policy_key,
                                                           event_id: event.id,
                                                           details: { "documents" => mismatched.map(&:document_key) })
        end

        if subject && event.subject_key.present? &&
           event.subject_key != StatementState.subject_key_for(subject)
          return Result.failure(:wrong_subject, policy_key: event.policy_key, event_id: event.id)
        end

        if !acting_for.equal?(UNSPECIFIED) &&
           event.represented_party_reference.to_s != Reference.represented_party(acting_for).to_s
          return Result.failure(:represented_party_mismatch,
                                policy_key: event.policy_key, event_id: event.id)
        end

        Result.success(
          policy_key: event.policy_key,
          event_id: event.id,
          details: { "request_evidence_binding" => event.request_evidence_binding_status.to_s }
        )
      end

      def load_states(policy, actor_reference, tenant, subject, acting_for)
        StatementState
          .for_policy(policy.key)
          .for_actor(actor_reference)
          .where(
            tenant_key: tenant_key_for(tenant),
            subject_key: StatementState.subject_key_for(subject),
            represented_party_reference: Reference.represented_party(acting_for)
          )
          .index_by(&:statement_key)
      end

      def reference_for(actor)
        Reference.actor(actor)
      end

      def tenant_key_for(tenant)
        Reference.tenant(tenant)
      end

      def subject_fingerprint_for(statement, subject)
        return nil if subject.nil? || statement.subject_fingerprint_with.nil?

        value = statement.subject_fingerprint_with.call(subject)
        value.nil? ? nil : Digest.digest(value.to_s)
      end

      # Returns the document key whose current published version is newer than
      # the one this evidence was captured against, or nil when everything the
      # statement requires is still current.
      def stale_document?(statement, state)
        recorded = Array(state.document_version_ids).map(&:to_s)

        statement.document_keys.find do |document_key|
          document = ::Clickwrap::Document.find_by(
            document_key: document_key,
            tenant_key: state.tenant_key.presence
          )
          current = document&.current_version(locale: I18n.locale)

          current && !recorded.include?(current.id.to_s)
        end
      end
    end
  end
end
