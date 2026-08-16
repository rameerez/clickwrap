# frozen_string_literal: true

module Clickwrap
  module Import
    # `Clickwrap.import_legacy!` — bring an `accepted_terms_at` column, a
    # bespoke audit table, or any other pre-Clickwrap record into the event log
    # without inventing anything that was never recorded.
    #
    # ===========================================================================
    # The governing rule: HISTORICAL WEAKNESS STAYS VISIBLE RATHER THAN BEING
    # LAUNDERED INTO MODERN CERTAINTY.
    #
    # An import is the single easiest place in this gem to manufacture evidence
    # by accident. Every field a modern capture fills in is sitting right there
    # with an obvious plausible value: the current Terms text, today's document
    # digest, the submit-button label from the current view, the assertion
    # sentence from the current policy, an IP address from the user's last
    # session. Writing any of them here would produce a row that is
    # indistinguishable from a real capture and is, in the parts that matter, a
    # fabrication.
    #
    # So this importer NEVER synthesizes:
    #
    #   * a presentation manifest — nobody signed one, and there is no offer to
    #     reproduce;
    #   * an assertion — we do not know the sentence the old system offered;
    #   * submit-button text — we do not know what the control said;
    #   * an IP address or browser user-agent — these were not observed by us,
    #     and a later session's address is a different fact about a different
    #     request;
    #   * document bytes or a digest — unless the caller can point at a version
    #     that is actually published here.
    #
    # Every key the caller lists in `unknown:` is recorded explicitly as unknown
    # in a structured field on the event, AND said in plain words in the
    # assertion text of each statement — which is inside the digested canonical
    # body, so the admission travels with the evidence rather than beside it.
    #
    # The event also keeps `occurred_at` (when it happened, according to the old
    # record) strictly separate from `recorded_at_by_server` (when we wrote it
    # down). That gap is a fact about the evidence and it stays visible.
    # ===========================================================================
    class Legacy
      # What an import did, or would do. Returned by both the dry run and the
      # real thing so a migration script reads the same either way.
      Result = Data.define(:status, :policy_key, :actor_reference, :occurred_at,
                           :recorded_at_by_server, :known, :unknown, :statement_keys,
                           :counts_as_current, :idempotency_key, :event, :message) do
        def imported? = status == :imported
        def already_imported? = status == :already_imported
        def planned? = status == :planned
        def written? = !event.nil?
        def receipt = event && Receipt.new(event)
        def event_id = event&.id
        def to_s = message
      end

      # The capture channels an import may claim. `imported_provider` means the
      # record came from another system; `system` means this application wrote
      # it without a human at a keyboard. Neither is `web_browser`, because no
      # browser was involved and a receipt that said otherwise would be wrong.
      PERMITTED_CHANNELS = %w[imported_provider system].freeze

      # Naming an unknown as unknown is the whole point, so the vocabulary is
      # open: a host may list any key it wants. These are the ones the README
      # and the FinePrint importer use, kept here so a typo in a migration
      # script is at least visibly a typo next to its neighbours.
      CONVENTIONAL_UNKNOWN_KEYS = %w[
        exact_document_bytes
        document_version
        presentation
        presentation_manifest
        assertion
        submit_button_text
        protected_action
        request_evidence
        ip_address
        browser_user_agent
        capture_channel
        authentication_context
      ].freeze

      def initialize(policy:, actor:, occurred_at:, because:, known: {}, unknown: [],
                     dry_run: false, subject: nil, tenant: nil, statements: nil,
                     capture_channel: "imported_provider", source: nil,
                     counts_as_current: true)
        @policy = policy
        @actor = actor
        @occurred_at = coerce_time(occurred_at)
        @because = because.to_s
        @known = normalize_known(known)
        @unknown = normalize_unknown(unknown)
        @dry_run = dry_run
        @subject = subject
        @tenant = tenant
        @statement_keys = statements&.map(&:to_s)
        @capture_channel = capture_channel.to_s
        @source = source&.to_s
        @counts_as_current = counts_as_current == true
      end

      attr_reader :policy, :actor, :occurred_at, :because, :known, :unknown, :dry_run,
                  :subject, :tenant, :capture_channel, :source, :counts_as_current

      def import!
        validate!

        existing = Event.find_by(policy_key: policy.key, idempotency_key: idempotency_key)
        return already_imported(existing) if existing

        return planned if dry_run

        write!
      end

      alias call import!

      # The derived key. Two runs of the same migration script over the same
      # legacy row produce the same key, so re-running an import is a no-op
      # rather than a second history for the same person.
      #
      # It covers what the legacy record actually said: who, which policy, which
      # subject and tenant, when it happened, and every `known:` value. Change
      # any of those and it is a different import, which is correct — a
      # different claim deserves a different event rather than silently
      # colliding with the first one.
      def idempotency_key
        @idempotency_key ||= "imported_legacy:#{Digest.hex(CanonicalJson.generate(identity_body))}"
      end

      private

      def identity_body
        {
          "policy" => policy.key,
          "actor" => actor_reference,
          "subject" => subject_key,
          "tenant" => tenant_key,
          "occurred_at" => Receipt.format_time(occurred_at),
          "statements" => statements_to_import.map(&:key),
          "known" => known,
          "unknown" => unknown,
          "source" => source,
          "capture_channel" => capture_channel,
          "counts_as_current" => counts_as_current,
          "because" => because
        }
      end

      def validate!
        policy.validate_tenant!(tenant)

        if because.strip.empty?
          raise ArgumentError,
                "Importing legacy evidence needs a `because:` in plain English saying where the " \
                "record came from — \"Imported from users.accepted_terms_at\" is exactly right. " \
                "It is stored on the event, and years from now it is the only thing that will " \
                "explain to a reader why this row does not look like a normal capture."
        end

        if occurred_at.nil?
          raise ArgumentError,
                "Importing legacy evidence needs `occurred_at:` — the time the old record says " \
                "this happened. Clickwrap will not substitute the time of the import, because " \
                "the distance between when something happened and when it was written down is " \
                "itself evidence. If the legacy row genuinely has no time, do not import it as " \
                "an act; record an exemption with `Clickwrap.exempt!` instead."
        end

        return if PERMITTED_CHANNELS.include?(capture_channel)

        raise ArgumentError,
              "An import cannot claim capture channel #{capture_channel.inspect}. An imported " \
              "record was not captured through a presentation this application rendered, so it " \
              "is one of: #{PERMITTED_CHANNELS.join(", ")}."
      end

      def statements_to_import
        if @statement_keys
          @statement_keys.map { |key| policy.statement!(key) }
        else
          # Optional statements are deliberately excluded. A legacy boolean
          # column recorded one decision; reading it as a grant of an optional
          # consent purpose it never mentioned would invent the very thing an
          # optional control exists to keep honest. Name them in `statements:`
          # if the old record really did cover them.
          policy.required_statements
        end
      end

      def write!
        now = Clickwrap.now
        revision = PolicyRevision.freeze_legacy_import_for(
          policy,
          source: source,
          statements: statements_to_import,
          known: known,
          unknown: unknown
        )
        event = nil

        ::ActiveRecord::Base.transaction do
          # Actor lock BEFORE the event insert: saving the event reserves the
          # chain head, and every writer takes these two locks actor-first
          # (the order capture uses) so concurrent paths cannot deadlock.
          StatementIdentityLock.acquire_for_actor!(actor_reference)

          event = build_event(now, revision)
          build_statements(event, now)
          build_documents(event)

          event.save!
          event.finalize_integrity!
          # Project into current state, exactly as a capture would: the point
          # of a migration is that `agreed_to?` keeps answering what the old
          # system answered. The projection carries this event's id, so the
          # imported provenance is one join away from every "yes".
          CurrentState.apply!(event) if counts_as_current
        end

        Result.new(
          status: :imported, policy_key: policy.key, actor_reference: actor_reference,
          occurred_at: occurred_at, recorded_at_by_server: now, known: known, unknown: unknown,
          statement_keys: statements_to_import.map(&:key), counts_as_current: counts_as_current,
          idempotency_key: idempotency_key,
          event: event,
          message: "Imported #{policy.key} for #{actor_reference} as event #{event.id}. " \
                   "#{unknown_sentence}"
        )
      end

      def build_event(now, revision)
        Event.new(
          event_type: "imported_legacy",
          policy_key: policy.key,
          policy_revision: revision,
          actor: actor.is_a?(::ActiveRecord::Base) ? actor : nil,
          actor_reference: actor_reference,
          tenant_key: tenant_key.presence,
          subject: subject.is_a?(::ActiveRecord::Base) ? subject : nil,
          subject_key: subject_key,
          capture_channel: capture_channel,
          # Not `authenticated_session`, not `unknown`: this record reached us
          # from somewhere else, and that is a different fact from "we do not
          # know how they were attributed".
          attribution_method: "imported_provider",
          # The two times stay apart. `occurred_at` is what the old record says;
          # `recorded_at_by_server` is when this row was written. Collapsing
          # them would quietly upgrade a migration into a contemporaneous
          # observation.
          occurred_at: occurred_at,
          recorded_at_by_server: now,
          idempotency_key: idempotency_key,
          provider_receipt: known.presence,
          provider_verification: import_provenance(now),
          reason: because,
          retention_class_key: policy.retention_class_key,
          canonical_schema_version: Clickwrap::CANONICAL_SCHEMA_VERSION,
          gem_version: Clickwrap::VERSION,
          application_version: Clickwrap.config.resolved_application_version,
          created_at: now
          # presentation_manifest and presentation_manifest_digest are left
          # unset on purpose. There was no manifest. A synthesized one would be
          # a signed description of an offer nobody made.
        )
      end

      # The structured record of what this import knew and what it did not. It
      # lives on the event so a reader never has to reconstruct the migration
      # script to find out which parts of a receipt are missing on purpose.
      def import_provenance(now)
        {
          "import_method" => "legacy_record",
          "source" => source,
          "because" => because,
          "imported_at" => Receipt.format_time(now),
          "occurred_at_source" => Receipt.format_time(occurred_at),
          "known" => known,
          "unknown" => unknown,
          "counts_as_current" => counts_as_current,
          "not_collected" => %w[presentation_manifest ip_address browser_user_agent ip_geolocation],
          "means" => "Recorded from a pre-existing record in this application or another system. " \
                     "Clickwrap did not present this content and did not observe this action. " \
                     "The fields listed under \"unknown\" were not recorded by whatever did."
        }.compact
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
            # No answer was captured by this application. The action records
            # what the old system says happened; `answered` records whether we
            # have the answer itself, and we do not.
            answer: nil,
            answered: false,
            purpose_key: statement.purpose_key,
            withdrawal_path: statement.withdrawal_path,
            valid_from: occurred_at,
            expires_at: statement.expires_after(occurred_at),
            one_time: statement.one_time?,
            requires: statement.requires,
            created_at: now
          )
        end
      end

      # The sentence that goes in the receipt. It is deliberately not the
      # policy's current assertion text: that sentence may have been written
      # years after the act, and putting it here would claim the source system
      # offered wording that may not have existed yet.
      def assertion_text_for(statement)
        [
          "Imported from a pre-existing record: it states that this actor " \
          "#{Vocabulary.initial_action_for(statement.kind)} #{statement.key} " \
          "on #{Receipt.format_time(occurred_at)}.",
          "The source system's original offer wording was not recorded, so this receipt does " \
          "not reproduce it.",
          unknown_sentence,
          because
        ].compact.reject(&:empty?).join(" ")
      end

      def unknown_sentence
        return "" if unknown.empty?

        "Not recorded by the source and therefore unknown: #{unknown.join(", ")}."
      end

      # Documents are linked only when the caller can point at bytes that are
      # actually published here AND has not told us the bytes are unknown. A
      # version label alone is a claim about a label, not about content, and an
      # EventDocument row asserts a digest.
      def build_documents(event)
        return if unknown.intersect?(%w[exact_document_bytes document_version])

        label = known["document_version"]
        return if label.blank?

        ordinal = 0

        statements_to_import.each do |statement|
          statement.document_keys.each do |document_key|
            version = published_version(document_key, label)
            next unless version

            event.documents.build(
              statement_key: statement.key,
              document_key: document_key,
              document_version_id: version.id,
              version_label: version.version_label,
              locale: version.locale,
              source_media_type: version.media_type,
              source_content_digest: version.content_digest,
              rendered_media_type: version.rendered_media_type.presence || version.media_type,
              rendered_content_digest: version.rendered_content_digest.presence || version.content_digest,
              renderer_name: version.renderer_name,
              renderer_version: version.renderer_version,
              sanitizer_name: version.sanitizer_name,
              sanitizer_version: version.sanitizer_version,
              ordinal: ordinal,
              created_at: event.recorded_at_by_server
            )

            ordinal += 1
          end
        end
      end

      def published_version(document_key, label)
        document = ::Clickwrap::Document.find_by(
          document_key: document_key,
          tenant_key: tenant_key.presence
        )
        document ||= ::Clickwrap::Document.find_by(document_key: document_key, tenant_key: nil)
        return nil unless document

        document.versions.find_by(version_label: label.to_s)
      end

      def already_imported(event)
        Result.new(
          status: :already_imported, policy_key: policy.key, actor_reference: actor_reference,
          occurred_at: occurred_at, recorded_at_by_server: event.recorded_at_by_server,
          known: known, unknown: unknown, statement_keys: event.statements.map(&:statement_key),
          counts_as_current: event.provider_verification.to_h.fetch("counts_as_current", true),
          idempotency_key: idempotency_key, event: event,
          message: "Already imported as event #{event.id}; nothing was written."
        )
      end

      def planned
        Result.new(
          status: :planned, policy_key: policy.key, actor_reference: actor_reference,
          occurred_at: occurred_at, recorded_at_by_server: nil, known: known, unknown: unknown,
          statement_keys: statements_to_import.map(&:key), counts_as_current: counts_as_current,
          idempotency_key: idempotency_key,
          event: nil,
          message: "Would import #{policy.key} for #{actor_reference} " \
                   "(#{statements_to_import.map(&:key).join(", ")}). #{unknown_sentence}".strip
        )
      end

      def normalize_known(raw)
        (raw || {}).to_h { |key, value| [key.to_s, value&.to_s] }.compact
      end

      def normalize_unknown(raw)
        Array(raw).map(&:to_s).reject(&:empty?).uniq.sort
      end

      # Legacy times arrive in whatever shape the old system stored them: a Time,
      # a Date, an ActiveSupport::TimeWithZone, or — when a migration reads
      # another gem's table through a raw connection — a plain String. All of
      # them are coerced to UTC here rather than at four call sites, and an
      # unparseable value becomes nil so `validate!` refuses the import with a
      # sentence instead of raising NoMethodError somewhere downstream.
      def coerce_time(value)
        return nil if value.nil?
        return value.utc if value.respond_to?(:utc)

        parsed = value.respond_to?(:to_time) ? value.to_time : Time.parse(value.to_s)
        parsed&.utc
      rescue ArgumentError, TypeError
        nil
      end

      def actor_reference
        @actor_reference ||= Reference.actor(actor)
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
