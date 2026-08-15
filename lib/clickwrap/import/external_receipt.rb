# frozen_string_literal: true

module Clickwrap
  module Import
    # `Clickwrap.import_external_receipt!` — record that another system owned
    # the presentation, and say so.
    #
    # ===========================================================================
    # When Stripe or DocuSign owned the presentation, DO NOT PRETEND YOUR
    # APPLICATION CAPTURED IT.
    #
    # Someone else rendered the page. Someone else chose the wording, the
    # ordering, the call to action, and whether the control started unselected.
    # Someone else observed the click, if a click is even what happened. Your
    # application learned about it afterwards, through an API response or a
    # webhook, and what you hold is their account of it.
    #
    # An event written here is therefore built so that it CANNOT be mistaken for
    # a local capture, by a person or by a query:
    #
    #   * `event_type` is `external_receipt`, not `capture`;
    #   * `capture_channel` is `imported_provider`;
    #   * `attribution_method` is `imported_provider`;
    #   * there is NO presentation manifest and no manifest digest, because
    #     there is no offer of ours to reproduce;
    #   * `Event#human_action?` is false, so it never satisfies a predicate that
    #     asks whether a person acted through a Clickwrap presentation; and
    #   * the receipt carries the provider's name, their event id, their raw
    #     receipt, and the validation state of whatever check we ran on it.
    #
    # It participates in host verification — this is real evidence and refusing
    # to record it would only push it somewhere worse — but it participates as
    # what it is. A provider receipt is upgraded into no guarantee the provider
    # did not make.
    # ===========================================================================
    class ExternalReceipt
      def initialize(policy:, actor:, provider_name:, provider_event_id:, provider_receipt: nil,
                     verified_with: nil, verified_at: nil, occurred_at: nil, subject: nil,
                     tenant: nil, because: nil, statements: nil)
        @policy = policy
        @actor = actor
        @provider_name = provider_name.to_s
        @provider_event_id = provider_event_id.to_s
        @provider_receipt = provider_receipt
        @verified_with = verified_with&.to_s
        @verified_at = coerce_time(verified_at)
        @occurred_at = coerce_time(occurred_at)
        @subject = subject
        @tenant = tenant
        @because = because
        @statement_keys = statements&.map(&:to_s)
      end

      attr_reader :policy, :actor, :provider_name, :provider_event_id, :provider_receipt,
                  :verified_with, :verified_at, :occurred_at, :subject, :tenant, :because

      # Returns the `Clickwrap::Event`, not a Receipt. Callers of an importer
      # almost always want to look straight at the labelling — `event_type`,
      # `capture_channel`, `provider_name`, and the deliberately absent
      # `presentation_manifest_digest` — because that labelling is the point.
      # `Clickwrap.receipt(event.id)` is one call away when a receipt is wanted.
      def import!
        validate!

        existing = Event.find_by(policy_key: policy.key, idempotency_key: idempotency_key)
        return existing if existing

        now = Clickwrap.now
        revision = PolicyRevision.freeze_for(policy)
        event = nil

        ::ActiveRecord::Base.transaction do
          event = build_event(now, revision)
          build_statements(event, now)

          event.save!
          CurrentState.apply!(event.reload)
        end

        event
      end

      alias call import!

      # One provider event is one Clickwrap event, forever. A webhook delivered
      # three times, a reconciliation sweep, and a backfill script all land on
      # the same key, so the same provider receipt cannot become two pieces of
      # evidence that an auditor would have to reconcile by hand.
      def idempotency_key
        "external_receipt:#{provider_name}:#{provider_event_id}"
      end

      private

      def validate!
        if provider_name.strip.empty?
          raise ArgumentError,
                "An imported receipt needs `provider_name:`. \"Some provider said so\" is not " \
                "provenance, and the name is what tells a reader years from now whose account " \
                "of events this row contains."
        end

        return unless provider_event_id.strip.empty?

        raise ArgumentError,
              "An imported receipt needs `provider_event_id:` — the provider's own identifier " \
              "for this act. It is how the same webhook delivered twice becomes one event " \
              "instead of two, and how anyone can go back and ask the provider about it."
      end

      def statements_to_import
        return @statement_keys.map { |key| policy.statement!(key) } if @statement_keys

        # Optional statements are excluded for the same reason they are excluded
        # from a legacy import: a provider receipt that says the account holder
        # accepted a service agreement says nothing about an optional purpose it
        # never presented.
        policy.required_statements
      end

      def build_event(now, revision)
        Event.new(
          event_type: "external_receipt",
          policy_key: policy.key,
          policy_revision: revision,
          actor: actor.is_a?(::ActiveRecord::Base) ? actor : nil,
          actor_reference: actor_reference,
          tenant_key: tenant_key.presence,
          subject: subject.is_a?(::ActiveRecord::Base) ? subject : nil,
          subject_key: subject_key,
          capture_channel: "imported_provider",
          attribution_method: "imported_provider",
          occurred_at: occurred_at,
          recorded_at_by_server: now,
          idempotency_key: idempotency_key,
          provider_name: provider_name,
          provider_event_id: provider_event_id,
          provider_receipt: normalized_provider_receipt,
          provider_verification: verification_record,
          reason: because,
          retention_class_key: policy.retention_class_key,
          canonical_schema_version: Clickwrap::CANONICAL_SCHEMA_VERSION,
          gem_version: Clickwrap::VERSION,
          application_version: Clickwrap.config.resolved_application_version,
          created_at: now
          # No presentation_manifest. Deliberately, permanently. The provider
          # rendered whatever was rendered; there is no offer of ours to sign,
          # and a synthesized one would make this row look like a capture.
        )
      end

      # What we did to check the provider's account of events, stated at the
      # strength it actually has. `checked_against_provider` means we asked them
      # and they confirmed. `not_checked` means the value arrived and we took
      # it at face value — which is a perfectly ordinary thing to do and a
      # completely different claim.
      def verification_record
        {
          "verified_with" => verified_with,
          "verified_at" => Receipt.format_time(verified_at),
          "state" => verified_with.present? ? "checked_against_provider" : "not_checked",
          "means" => "Provenance and validation state of one provider's receipt as recorded by " \
                     "this application. It preserves exactly the assurance that provider " \
                     "supplied, and adds none. Clickwrap did not present this content and did " \
                     "not observe this action."
        }.compact
      end

      def normalized_provider_receipt
        case provider_receipt
        when nil then nil
        when Hash then provider_receipt.deep_stringify_keys
        when String then { "value" => provider_receipt }
        else
          return { "value" => provider_receipt.to_s } unless provider_receipt.respond_to?(:to_h)

          provider_receipt.to_h.deep_stringify_keys
        end
      end

      def build_statements(event, now)
        statements_to_import.each_with_index do |statement, index|
          event.statements.build(
            ordinal: index,
            statement_key: statement.key,
            kind: statement.kind,
            action: statement.initial_action,
            assertion_text: assertion_text_for(statement),
            assertion_locale: "en",
            required: statement.required?,
            optional: statement.optional?,
            answer: nil,
            answered: false,
            purpose_key: statement.purpose_key,
            withdrawal_path: statement.withdrawal_path,
            valid_from: occurred_at || now,
            expires_at: statement.expires_after(occurred_at || now),
            one_time: statement.one_time?,
            requires: statement.requires,
            created_at: now
          )
        end
      end

      def assertion_text_for(statement)
        "Recorded from #{provider_name}'s receipt #{provider_event_id}: it states that this " \
          "actor #{Vocabulary.initial_action_for(statement.kind)} #{statement.key}. " \
          "#{provider_name} owned the presentation, so the exact wording, controls, and call to " \
          "action shown are theirs and were not recorded here."
      end

      def actor_reference
        @actor_reference ||=
          if actor.is_a?(String)
            actor
          else
            Clickwrap.config.identify_actor_with.call(actor)
          end
      end

      # Provider timestamps arrive as whatever the API client handed over — a
      # Time, a TimeWithZone, or an ISO 8601 String straight off the wire. All of
      # them become UTC here, and an unparseable one becomes nil rather than
      # crashing a webhook handler over a field that is provenance, not evidence.
      def coerce_time(value)
        return nil if value.nil?
        return value.utc if value.respond_to?(:utc)

        parsed = value.respond_to?(:to_time) ? value.to_time : Time.parse(value.to_s)
        parsed&.utc
      rescue ArgumentError, TypeError
        nil
      end

      def subject_key = StatementState.subject_key_for(subject)

      def tenant_key
        return "" if tenant.nil?
        return tenant.to_s if tenant.is_a?(String) || tenant.is_a?(Symbol)
        return tenant.to_gid.to_s if tenant.respond_to?(:to_gid)

        "#{tenant.class.name}/#{tenant.id}"
      end
    end
  end
end
