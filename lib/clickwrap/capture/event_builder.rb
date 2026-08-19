# frozen_string_literal: true

module Clickwrap
  class Capture
    # Builds one complete, unsaved event graph from already verified input.
    # Persistence/idempotency stay in Capture because they decide whether the
    # protected block may run; this collaborator only constructs evidence.
    class EventBuilder
      Result = Data.define(:event, :request_evidence_annex)

      def initialize(policy:, manifest:, revision:, statement_snapshots:, answers:,
                     document_versions_by_id:, request_evidence:, event_type:,
                     root_event_id:, predecessor_event_id:, actor:, actor_reference:,
                     actor_snapshot:, represented_party:, authority_decision:, tenant_key:,
                     subject:, subject_key:, subject_fingerprint:, capture_channel:,
                     authentication_context:, attribution_method:, idempotency_key:,
                     http_request_id:, http_route_name:, reason:, statement_action_overrides:)
        @policy = policy
        @manifest = manifest
        @revision = revision
        @statement_snapshots = statement_snapshots
        @answers = answers
        @document_versions_by_id = document_versions_by_id
        @request_evidence = request_evidence
        @event_type = event_type
        @root_event_id = root_event_id
        @predecessor_event_id = predecessor_event_id
        @actor = actor
        @actor_reference = actor_reference
        @actor_snapshot = actor_snapshot
        @represented_party = represented_party
        @authority_decision = authority_decision
        @tenant_key = tenant_key
        @subject = subject
        @subject_key = subject_key
        @subject_fingerprint = subject_fingerprint
        @capture_channel = capture_channel
        @authentication_context = authentication_context
        @attribution_method = attribution_method
        @idempotency_key = idempotency_key
        @http_request_id = http_request_id
        @http_route_name = http_route_name
        @reason = reason
        @statement_action_overrides = statement_action_overrides
      end

      def build
        now = Clickwrap.now
        event_id = Identifier.generate(now)
        annex = build_request_evidence_annex(event_id)
        event = build_event(event_id, annex, now)

        build_statements(event, now)
        build_documents(event)

        Result.new(event: event, request_evidence_annex: annex)
      end

      private

      attr_reader :policy, :manifest

      def build_event(event_id, annex, now)
        Event.new(
          id: event_id,
          request_evidence_category_binding_digests: annex&.category_binding_digests || {},
          request_evidence_digest_algorithm: annex&.binding_digest_algorithm,
          request_evidence_key_id: annex&.binding_key_id,
          event_type: @event_type,
          policy_key: policy.key,
          policy_revision: @revision,
          root_event_id: @root_event_id,
          predecessor_event_id: @predecessor_event_id,
          actor: persisted_record(@actor),
          actor_reference: @actor_reference,
          actor_snapshot: @actor_snapshot,
          represented_party: persisted_record(@represented_party),
          represented_party_reference: represented_party_reference,
          authority_source: @authority_decision&.source,
          authority_role: @authority_decision&.role,
          authority_verified_at: @authority_decision&.verified_at,
          authority_details: @authority_decision&.details || {},
          tenant_key: @tenant_key.presence,
          subject: persisted_record(@subject),
          subject_key: @subject_key,
          subject_fingerprint: @subject_fingerprint,
          capture_channel: @capture_channel,
          authentication_method: @authentication_context[:method]&.to_s,
          authentication_context: @authentication_context,
          attribution_method: @attribution_method,
          recorded_at_by_server: now,
          idempotency_key: @idempotency_key,
          http_request_id: @http_request_id,
          http_route_name: @http_route_name,
          presentation: persisted_presentation,
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
      end

      def build_statements(event, now)
        @statement_snapshots.each_value.with_index do |statement, index|
          key = statement.fetch("key")
          fragment = manifest.statement(key) || {}
          answer = @answers[key]
          answered = statement["choices"] ? answer.present? : Submission.affirmative?(answer)

          # Silence on an optional control is an offer not taken, not an
          # affirmative refusal. It creates no grant statement.
          next if statement["optional"] && !answered

          event.statements.build(
            ordinal: index,
            statement_key: key,
            kind: statement["kind"],
            action: action_for(statement, answer, answered),
            assertion_text: fragment["assertion"],
            assertion_locale: manifest.locale,
            label_text: fragment["label"],
            link_labels: Array(fragment["documents"]).to_h { |document| [document["key"], document["label"]] },
            choices: statement["choices"],
            required: statement["required"],
            optional: statement["optional"],
            answer: answer,
            answered: answered,
            purpose_key: statement["purpose_key"],
            withdrawal_path: statement["withdrawal_path"],
            valid_from: now,
            expires_at: policy.statement!(key).expires_after(now),
            one_time: statement["one_time"],
            requires: statement["requires"],
            subject_fingerprint: fragment["subject_fingerprint"],
            created_at: now
          )
        end
      end

      def action_for(statement, answer, answered)
        override = @statement_action_overrides[statement.fetch("key")]
        return override if override

        initial = Vocabulary.initial_action_for(statement.fetch("kind"))
        return initial unless statement["choices"] && answered

        case statement["choices"][answer.to_s]
        when "grant" then initial
        when "decline" then "declined"
        else statement["choices"][answer.to_s]
        end
      end

      def build_documents(event)
        ordinal = 0

        manifest.statements.each do |statement|
          Array(statement["documents"]).each do |document|
            version = @document_versions_by_id.fetch(document["version_id"].to_s)

            event.documents.build(
              statement_key: statement["key"],
              document_key: document["key"],
              document_version_id: version.id,
              version_label: document["version"],
              locale: document["locale"],
              source_media_type: document["source_media_type"],
              source_content_digest: document["source_digest"],
              rendered_media_type: document["rendered_media_type"],
              rendered_content_digest: document["rendered_digest"],
              renderer_name: document.dig("renderer", "name"),
              renderer_version: document.dig("renderer", "version"),
              sanitizer_name: document.dig("renderer", "sanitizer_name"),
              sanitizer_version: document.dig("renderer", "sanitizer_version"),
              ordinal: ordinal,
              created_at: event.recorded_at_by_server
            )

            ordinal += 1
          end
        end
      end

      def build_request_evidence_annex(event_id)
        return nil if @request_evidence.nil? || !@request_evidence.records_anything?

        # Idempotent, and applied here as well as at boot: declaring an
        # encrypted attribute reads the column, so an application whose
        # database was not reachable during initialization would otherwise
        # write this annex in plain text without anyone noticing.
        RequestEvidence.apply_configured_encryption!

        RequestEvidence.new(
          @request_evidence.attributes.merge(event_id: event_id, created_at: Clickwrap.now)
        )
      end

      def represented_party_reference
        return "" if @represented_party.nil?

        Reference.represented_party(@represented_party)
      end

      def persisted_record(value)
        value if value.is_a?(::ActiveRecord::Base)
      end

      def persisted_presentation
        return nil unless policy.persist_presentations?

        Presentation.find_by(nonce: manifest.nonce)
      end
    end
  end
end
