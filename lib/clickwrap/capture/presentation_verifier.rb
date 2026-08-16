# frozen_string_literal: true

module Clickwrap
  class Capture
    # Verifies the complete render-to-submit contract before Capture opens a
    # database transaction. It owns no writes: its result is the frozen input
    # the transaction is allowed to turn into an evidence event.
    class PresentationVerifier
      Result = Data.define(
        :manifest,
        :revision,
        :statement_snapshots,
        :answers,
        :document_versions_by_id,
        :capture_channel
      )

      def initialize(policy:, submission:, explicit_answers:, actor_reference:, tenant_key:,
                     subject_key:, subject_fingerprint:, represented_party:,
                     prospective_actor:, registration_flow_id:, explicit_capture_channel:,
                     represented_party_creation_flow_id: nil,
                     creating_represented_party: false)
        @policy = policy
        @submission = submission
        @explicit_answers = explicit_answers
        @actor_reference = actor_reference
        @tenant_key = tenant_key
        @subject_key = subject_key
        @subject_fingerprint = subject_fingerprint
        @represented_party = represented_party
        @prospective_actor = prospective_actor
        @registration_flow_id = registration_flow_id
        @explicit_capture_channel = explicit_capture_channel
        @represented_party_creation_flow_id = represented_party_creation_flow_id
        @creating_represented_party = creating_represented_party == true
      end

      def verify!(for_replay: false)
        manifest = submitted_manifest!
        capture_channel = @explicit_capture_channel || manifest.capture_channel.to_s

        verify_bindings!(manifest, capture_channel, for_replay: for_replay)
        document_versions = verify_document_digests!(manifest)
        revision = load_revision!(manifest, require_current_policy: !for_replay)
        statement_snapshots = frozen_statement_snapshots(revision)
        verify_manifest_matches_revision!(manifest, statement_snapshots)
        answers = collect_answers(manifest)
        validate_answers!(manifest, answers, statement_snapshots)

        Result.new(
          manifest: manifest,
          revision: revision,
          statement_snapshots: statement_snapshots.freeze,
          answers: answers.freeze,
          document_versions_by_id: document_versions.freeze,
          capture_channel: capture_channel.freeze
        )
      end

      private

      attr_reader :policy, :submission

      def submitted_manifest!
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

        manifest
      end

      def verify_bindings!(manifest, capture_channel, for_replay:)
        verify_registration_binding!(manifest)
        verify_actor_binding!(manifest)
        verify_tenant_binding!(manifest)
        verify_channel_binding!(manifest, capture_channel, for_replay: for_replay)
        verify_subject_binding!(manifest, for_replay: for_replay)
        verify_represented_party_binding!(manifest, for_replay: for_replay)
      end

      def verify_actor_binding!(manifest)
        return if manifest.registration_flow_id.present?
        return if manifest.actor_reference.present? && @actor_reference.present? &&
                  Digest.secure_compare?(manifest.actor_reference, @actor_reference)

        raise PresentationInvalid.new(
          "This presentation was issued to a different actor.",
          result: Verification::Result.failure(:presentation_actor_mismatch, policy_key: policy.key)
        )
      end

      def verify_tenant_binding!(manifest)
        return if manifest.tenant_key.to_s == @tenant_key.to_s

        raise PresentationInvalid.new(
          "This presentation was issued for a different tenant.",
          result: Verification::Result.failure(:presentation_tenant_mismatch, policy_key: policy.key)
        )
      end

      def verify_channel_binding!(manifest, capture_channel, for_replay:)
        unless manifest.capture_channel.to_s == capture_channel.to_s &&
               (for_replay || policy.permits_capture_channel?(capture_channel))
          raise PresentationInvalid.new(
            "Policy #{policy.key} does not accept this presentation's capture channel.",
            result: Verification::Result.failure(:presentation_channel_mismatch, policy_key: policy.key)
          )
        end
      end

      def verify_subject_binding!(manifest, for_replay:)
        if manifest.subject_key.to_s != @subject_key.to_s
          raise PresentationInvalid.new(
            "This presentation was issued for a different subject.",
            result: Verification::Result.failure(:presentation_subject_mismatch, policy_key: policy.key)
          )
        end

        # The committed event's immutable manifest digest and subject
        # fingerprint are checked by Capture#replay. Requiring the LIVE
        # pre-action fingerprint here would reject a safe retry whenever the
        # successful protected action itself changed that state.
        return if for_replay

        fingerprint_matches =
          if manifest.subject_fingerprint.blank? && @subject_fingerprint.blank?
            true
          else
            Digest.secure_compare?(manifest.subject_fingerprint.to_s, @subject_fingerprint.to_s)
          end
        return if fingerprint_matches

        raise PresentationInvalid.new(
          "The subject changed after this presentation was issued. Re-render it against the " \
          "subject's current state before acting.",
          result: Verification::Result.failure(:subject_fingerprint_mismatch, policy_key: policy.key)
        )
      end

      def verify_represented_party_binding!(manifest, for_replay:)
        if manifest.represented_party_will_be_created_by_protected_action?
          return verify_represented_party_creation_binding!(manifest, for_replay: for_replay)
        end

        if @creating_represented_party
          raise PresentationInvalid.new(
            "This presentation was issued for an already-existing represented party, not for creation.",
            result: Verification::Result.failure(
              :represented_party_creation_flow_mismatch,
              policy_key: policy.key
            )
          )
        end

        expected_reference = @represented_party.nil? ? "" : Reference.represented_party(@represented_party)
        expected_type = @represented_party&.class&.name.to_s

        unless Digest.secure_compare?(manifest.represented_party_reference.to_s, expected_reference) &&
               Digest.secure_compare?(manifest.represented_party_type.to_s, expected_type)
          raise PresentationInvalid.new(
            "This presentation was issued for a different represented party.",
            result: Verification::Result.failure(:represented_party_mismatch, policy_key: policy.key)
          )
        end

        authority_was_verified = @represented_party.nil? ||
                                 manifest.authority_at_presentation.to_h["state"] == "verified"
        return if for_replay || (manifest.authority_rule == policy.authority_rule&.to_snapshot &&
                                 authority_was_verified)

        raise PresentationInvalid.new(
          "The represented-party authority rule changed after this presentation was issued. Re-render it.",
          result: Verification::Result.failure(
            :represented_party_authority_mismatch,
            policy_key: policy.key
          )
        )
      end

      def verify_represented_party_creation_binding!(manifest, for_replay:)
        unless @creating_represented_party &&
               @represented_party.respond_to?(:new_record?) && @represented_party.new_record?
          raise PresentationInvalid.new(
            "A represented-party creation presentation must be completed through " \
            "`Clickwrap.create_represented_party!` with the exact new record.",
            result: Verification::Result.failure(
              :represented_party_creation_flow_mismatch,
              policy_key: policy.key
            )
          )
        end

        expected_flow_id = @represented_party_creation_flow_id.to_s
        expected_reference = "represented_party_creation/#{expected_flow_id}"
        binding_matches = expected_flow_id.present? &&
                          Digest.secure_compare?(
                            manifest.represented_party_creation_flow_id.to_s,
                            expected_flow_id
                          ) &&
                          Digest.secure_compare?(
                            manifest.represented_party_reference.to_s,
                            expected_reference
                          ) &&
                          Digest.secure_compare?(
                            manifest.represented_party_type.to_s,
                            @represented_party.class.name.to_s
                          )
        unless binding_matches
          raise PresentationInvalid.new(
            "This represented-party creation presentation belongs to a different browser flow or record type.",
            result: Verification::Result.failure(
              :represented_party_creation_flow_mismatch,
              policy_key: policy.key
            )
          )
        end

        authority_snapshot_is_honest =
          manifest.authority_at_presentation.to_h["state"] == "not_yet_verifiable"
        rule_matches = manifest.authority_rule == policy.authority_rule&.to_snapshot &&
                       policy.authority_rule&.allows_represented_party_creation?
        return if for_replay || (rule_matches && authority_snapshot_is_honest)

        raise PresentationInvalid.new(
          "The represented-party creation authority rule changed after this presentation was issued. Re-render it.",
          result: Verification::Result.failure(
            :represented_party_authority_mismatch,
            policy_key: policy.key
          )
        )
      end

      def verify_registration_binding!(manifest)
        if @prospective_actor
          if @prospective_actor.persisted?
            raise PresentationInvalid,
                  "Registration evidence can only be bound while the account is new — this " \
                  "prospective actor is already persisted. If you meant to capture for a " \
                  "verified person, use capture! with `actor:`. A typed email address on a " \
                  "public form is not identity proof: create a separate pending request, " \
                  "verify control of the address, and only then capture for the existing actor."
          end

          unless manifest.registration_flow_id.present? &&
                 Digest.secure_compare?(manifest.registration_flow_id.to_s, @registration_flow_id.to_s)
            raise PresentationInvalid.new(
              "This registration presentation belongs to a different browser registration flow.",
              result: Verification::Result.failure(:registration_flow_mismatch, policy_key: policy.key)
            )
          end

          return if manifest.prospective_actor_type == @prospective_actor.class.name

          raise PresentationInvalid.new(
            "This registration presentation was issued for a different account type.",
            result: Verification::Result.failure(:registration_actor_type_mismatch, policy_key: policy.key)
          )
        end

        return if manifest.registration_flow_id.blank?

        raise PresentationInvalid.new(
          "A registration presentation cannot be used as an ordinary signed-in capture.",
          result: Verification::Result.failure(:registration_flow_mismatch, policy_key: policy.key)
        )
      end

      def verify_document_digests!(manifest)
        verified = {}

        manifest.statements.each do |statement|
          Array(statement["documents"]).each do |document|
            version_id = document["version_id"].to_s
            version = verified[version_id] || DocumentVersion.find_by(id: document["version_id"])

            source_matches = version &&
                             Digest.secure_compare?(version.content_digest, document["source_digest"])
            rendered_matches = version && Digest.secure_compare?(
              version.rendered_content_digest.presence || version.content_digest,
              document["rendered_digest"]
            )
            metadata_matches = version &&
                               document["path"].present? &&
                               (version.rendered_media_type.presence || version.media_type) ==
                               document["rendered_media_type"] &&
                               version.media_type == document["source_media_type"]

            if source_matches && rendered_matches && metadata_matches &&
               version.verify_content_digest && version.verify_rendered_content_digest
              verified[version_id] = version
              next
            end

            raise PresentationInvalid.new(
              "The document #{document["key"]} version #{document["version"]} no longer matches " \
              "what this presentation offered. Re-render the form so the person sees the current " \
              "version before acting on it.",
              result: Verification::Result.failure(
                :document_digest_mismatch,
                policy_key: policy.key,
                details: { "document" => document["key"] }
              )
            )
          end
        end

        verified
      end

      def load_revision!(manifest, require_current_policy:)
        revision = PolicyRevision.find_by(
          policy_key: policy.key,
          revision_digest: manifest.revision_digest
        )

        unless revision
          raise PresentationInvalid.new(
            "The policy revision this presentation was issued under is no longer on file.",
            result: Verification::Result.failure(:stale_policy_revision, policy_key: policy.key)
          )
        end

        computed = Digest.digest_canonical(revision.compiled_snapshot)
        unless Digest.secure_compare?(computed, revision.revision_digest)
          raise PresentationInvalid.new(
            "The frozen policy revision no longer matches its recorded digest.",
            result: Verification::Result.failure(:integrity_check_failed, policy_key: policy.key)
          )
        end

        return revision unless require_current_policy
        return revision if revision.matches_loaded_policy?

        raise PresentationInvalid.new(
          "The policy changed after this presentation was issued. Re-render it so every " \
          "server-side rule and callback is the reviewed current revision.",
          result: Verification::Result.failure(:stale_policy_revision, policy_key: policy.key)
        )
      end

      def frozen_statement_snapshots(revision)
        Array(revision.compiled_snapshot["statements"]).index_by do |statement|
          statement.fetch("key")
        end
      end

      def verify_manifest_matches_revision!(manifest, statement_snapshots)
        manifest_keys = manifest.statements.map { |statement| statement["key"] }
        mismatch = manifest_keys != statement_snapshots.keys

        manifest.statements.each do |offered|
          frozen = statement_snapshots[offered["key"]]
          mismatch ||= frozen.nil? || manifest_structure(offered) != revision_structure(frozen)
        end

        return unless mismatch

        raise PresentationInvalid.new(
          "The presentation does not exactly match its frozen policy revision. Re-render it " \
          "instead of accepting ambiguous evidence.",
          result: Verification::Result.failure(:presentation_invalid, policy_key: policy.key)
        )
      end

      def manifest_structure(statement)
        {
          "key" => statement["key"],
          "kind" => statement["kind"],
          "documents" => Array(statement["documents"]).map { |document| document["key"] },
          "choices" => statement["choices"],
          "required" => statement["required"],
          "optional" => statement["optional"],
          "requires_an_explicit_choice" => statement["requires_an_explicit_choice"],
          "requires_current_version" => statement["requires_current_version"] || false,
          "one_time" => statement["one_time"] || false,
          "purpose_key" => statement["purpose"],
          "withdrawal_path" => statement["withdrawal_path"],
          "valid_for_seconds" => statement["valid_for_seconds"],
          "requires" => Array(statement["requires"]),
          "subject_fingerprint_version" => statement["subject_fingerprint_version"],
          "protected_outcome_version" => statement["protected_outcome_version"]
        }
      end

      def revision_structure(statement)
        keys = %w[
          key kind documents choices required optional requires_an_explicit_choice
          requires_current_version one_time purpose_key withdrawal_path valid_for_seconds
          requires subject_fingerprint_version protected_outcome_version
        ]

        keys.to_h { |key| [key, statement[key]] }
      end

      def collect_answers(manifest)
        return @explicit_answers.to_h.transform_keys(&:to_s) unless @explicit_answers.nil?

        manifest.statements.to_h do |statement|
          [statement["key"], submission.answer_for(statement["key"])]
        end
      end

      def validate_answers!(manifest, answers, statement_snapshots)
        submitted_keys = submission ? submission.answers.keys : answers.keys
        unknown = submitted_keys - manifest.statements.map { |statement| statement["key"] }

        unless unknown.empty?
          raise SubmissionInvalid,
                "The submission answers #{unknown.join(", ")}, which this presentation never " \
                "offered. Answers are only accepted for the statements the server declared."
        end

        statement_snapshots.each_value do |statement|
          validate_answer!(statement, answers[statement.fetch("key")])
        end
      end

      def validate_answer!(statement, value)
        if statement["choices"]
          validate_choice!(statement, value)
        elsif statement["required"] && !Submission.affirmative?(value)
          raise AnswerInvalid.new(
            "#{statement["key"]} is required and was not answered.",
            statement_key: statement["key"],
            reason: :missing_answer
          )
        end
      end

      def validate_choice!(statement, value)
        if value.blank?
          return unless statement["requires_an_explicit_choice"] || statement["required"]

          raise AnswerInvalid.new(
            "#{statement["key"]} needs an explicit choice; none was submitted.",
            statement_key: statement["key"],
            reason: :missing_answer
          )
        end

        return if statement["choices"].key?(value.to_s)

        raise AnswerInvalid.new(
          "#{value.inspect} is not one of the choices offered for #{statement["key"]} " \
          "(#{statement["choices"].keys.join(", ")}).",
          statement_key: statement["key"],
          reason: :missing_answer
        )
      end
    end
  end
end
