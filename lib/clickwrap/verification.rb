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
      def verify(policy_or_event, actor: nil, subject: nil, tenant: nil, policy: nil, at: nil)
        at ||= Clickwrap.now

        if policy_or_event.is_a?(String) && Identifier.valid?(policy_or_event)
          verify_event(policy_or_event, policy: policy, subject: subject, at: at)
        else
          verify_policy(policy_or_event, actor: actor, subject: subject, tenant: tenant, at: at)
        end
      end

      private

      def verify_policy(policy_key, actor:, subject:, tenant:, at:)
        policy = Clickwrap.policies[policy_key.to_s]

        unless policy
          return Result.failure(:unknown_policy, policy_key: policy_key.to_s)
        end

        actor_reference = reference_for(actor)

        unless actor_reference
          return Result.failure(:wrong_actor, policy_key: policy.key)
        end

        states = load_states(policy, actor_reference, tenant, subject)

        policy.required_statements.each do |statement|
          state = states[statement.key]

          unless state
            return Result.failure(:no_evidence, policy_key: policy.key, statement_key: statement.key)
          end

          failure = check_statement(policy, statement, state, subject, at)
          return failure if failure
        end

        newest = states.values.max_by(&:effective_at)
        Result.success(policy_key: policy.key, event_id: newest&.current_event_id,
                       details: { "statements" => states.keys.sort })
      end

      def check_statement(policy, statement, state, subject, at)
        unless state.satisfies?(at)
          return Result.failure(state.failure_reason(at), policy_key: policy.key,
                                statement_key: statement.key, event_id: state.current_event_id)
        end

        if statement.subject_bound?
          expected = subject_fingerprint_for(statement, subject)

          if expected && !Digest.secure_compare?(expected, state.subject_fingerprint.to_s)
            return Result.failure(:subject_fingerprint_mismatch, policy_key: policy.key,
                                  statement_key: statement.key, event_id: state.current_event_id)
          end
        end

        if statement.requires_current_version?
          stale = stale_document?(statement, state)

          if stale
            return Result.failure(:unseen_document_version, policy_key: policy.key,
                                  statement_key: statement.key, event_id: state.current_event_id,
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

      def verify_event(event_id, policy:, subject:, at:)
        event = Event.find_by(id: event_id)

        return Result.failure(:no_evidence, event_id: event_id) unless event

        if policy && event.policy_key != policy.to_s
          return Result.failure(:presentation_policy_mismatch, policy_key: event.policy_key,
                                event_id: event.id)
        end

        if event.disposed?
          return Result.failure(:core_event_disposed, policy_key: event.policy_key, event_id: event.id)
        end

        unless event.digest_verified?
          return Result.failure(:integrity_check_failed, policy_key: event.policy_key, event_id: event.id)
        end

        # Two different ways a document can stop matching, and both have to be
        # caught. The first is the version row being swapped or its recorded
        # digest changed. The second is subtler and more likely: the row keeps
        # its digest column while someone edits the bytes underneath it, which
        # would leave every receipt citing it silently describing content that
        # is no longer there. So the stored bytes get re-digested, not trusted.
        mismatched = event.documents.reject do |binding|
          binding.still_matches_stored_version? && binding.document_version&.verify_content_digest
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

        Result.success(policy_key: event.policy_key, event_id: event.id)
      end

      def load_states(policy, actor_reference, tenant, subject)
        StatementState
          .for_policy(policy.key)
          .for_actor(actor_reference)
          .where(tenant_key: tenant_key_for(tenant), subject_key: StatementState.subject_key_for(subject))
          .index_by(&:statement_key)
      end

      def reference_for(actor)
        return nil if actor.nil?

        Clickwrap.config.identify_actor_with.call(actor)
      end

      def tenant_key_for(tenant)
        return "" if tenant.nil?
        return tenant.to_s if tenant.is_a?(String) || tenant.is_a?(Symbol)
        return tenant.to_gid.to_s if tenant.respond_to?(:to_gid)

        "#{tenant.class.name}/#{tenant.id}"
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
          document = ::Clickwrap::Document.find_by(key: document_key, tenant_key: state.tenant_key.presence)
          current = document&.current_version(locale: I18n.locale)

          current && !recorded.include?(current.id.to_s)
        end
      end
    end
  end
end
