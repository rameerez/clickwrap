# frozen_string_literal: true

module Clickwrap
  # One digest-bound evidence event with fixed, named post-write transitions.
  #
  # A capture, a withdrawal, a correction, an expiry, a consumption, a
  # disposition, a hold — each is a row here, linked to what it acts on. The
  # ordinary `update` and `destroy` calls are refused. Finalization, pointer
  # nullification, request-evidence linking, legal-hold state, and reviewed core
  # disposition use explicit fixed write sets; lifecycle and disposition facts
  # append linked events explaining what happened and why. Optional PostgreSQL
  # hardening enforces those same sets below the model layer.
  #
  # What an event proves is bounded and stated in the receipt: the server
  # generated and accepted a particular presentation, an explicit action was
  # submitted against it, and it committed together with whatever domain action
  # it protected. It does not prove that a person read anything, understood
  # anything, saw particular pixels, or that a party controlling both the
  # application and the database could not have written the row.
  class Event < ApplicationRecord
    self.table_name = "clickwrap_events"
    self.primary_key = "id"

    # Ordinary mutation is not part of this model's contract. Rails' own
    # `touch`, counter caches, and `update_column` would all bypass the
    # callbacks below, so the columns those would reach simply do not exist:
    # there is no `updated_at`, no counter cache, and no lock version.
    self.record_timestamps = false

    # MySQL does not permit a default on a native JSON column. Keep the
    # portable NOT NULL guarantee by assigning the empty binding manifest in
    # the model for lifecycle/import events that have no request annex.
    attribute :request_evidence_category_binding_digests, default: -> { {} }

    # Named write sets used by the opt-in PostgreSQL hardening migration. They
    # document every post-INSERT path the gem itself needs, so the migration can
    # refuse to install if its trigger policy ever drifts from runtime code.
    FINALIZATION_COLUMNS = %w[
      chain_scope chain_sequence previous_event_digest event_digest
      digest_algorithm canonical_schema_version
    ].freeze
    POINTER_NULLIFICATION_COLUMNS = %w[
      actor_type actor_id represented_party_type represented_party_id
      subject_type subject_id
    ].freeze
    DISPOSITION_COLUMNS = %w[
      actor_type actor_id actor_reference actor_snapshot
      represented_party_type represented_party_id represented_party_reference
      authority_source authority_role authority_verified_at authority_details
      tenant_key subject_type subject_id subject_key subject_fingerprint
      authentication_method authentication_context idempotency_key
      http_request_id http_route_name presentation_id presentation_manifest
      presentation_manifest_digest protected_outcome provider_receipt
      provider_verification reason core_event_disposed_at
      core_event_disposition_event_id
    ].freeze
    MODEL_CALLBACK_MUTABLE_COLUMNS = %w[
      core_event_disposed_at core_event_disposition_event_id on_legal_hold request_evidence_id
    ].freeze
    MUTABLE_COLUMNS = MODEL_CALLBACK_MUTABLE_COLUMNS
    DATABASE_HARDENING_WRITE_SETS = {
      "finalization" => FINALIZATION_COLUMNS,
      "pointer_nullification" => POINTER_NULLIFICATION_COLUMNS,
      "disposition" => DISPOSITION_COLUMNS,
      "legal_hold" => %w[on_legal_hold].freeze,
      "request_evidence_link" => %w[request_evidence_id].freeze
    }.transform_values { |columns| columns.map(&:to_s).sort.freeze }.freeze

    belongs_to :policy_revision,
               class_name: "Clickwrap::PolicyRevision",
               optional: true,
               inverse_of: :events

    belongs_to :presentation,
               class_name: "Clickwrap::Presentation",
               optional: true,
               inverse_of: :events

    belongs_to :actor, polymorphic: true, optional: true
    belongs_to :subject, polymorphic: true, optional: true
    belongs_to :represented_party, polymorphic: true, optional: true

    has_many :statements,
             -> { order(:ordinal) },
             class_name: "Clickwrap::EventStatement",
             foreign_key: :event_id,
             inverse_of: :event,
             dependent: :restrict_with_error

    has_many :documents,
             -> { order(:ordinal) },
             class_name: "Clickwrap::EventDocument",
             foreign_key: :event_id,
             inverse_of: :event,
             dependent: :restrict_with_error

    has_one :request_evidence,
            class_name: "Clickwrap::RequestEvidence",
            foreign_key: :event_id,
            inverse_of: :event,
            dependent: :restrict_with_error

    has_many :legal_holds,
             class_name: "Clickwrap::LegalHold",
             foreign_key: :event_id,
             inverse_of: :event,
             dependent: :restrict_with_error

    has_many :accesses,
             class_name: "Clickwrap::ReceiptAccess",
             foreign_key: :event_id,
             inverse_of: :event,
             dependent: :restrict_with_error

    has_many :integrity_attestations,
             -> { order(:attempted_at, :id) },
             class_name: "Clickwrap::IntegrityAttestation",
             foreign_key: :event_id,
             inverse_of: :event,
             dependent: :restrict_with_error

    has_one :external_action,
            class_name: "Clickwrap::ExternalAction",
            foreign_key: :event_id,
            inverse_of: :event,
            dependent: :restrict_with_error

    belongs_to :root_event, class_name: "Clickwrap::Event", optional: true
    belongs_to :predecessor_event, class_name: "Clickwrap::Event", optional: true

    has_many :successor_events,
             class_name: "Clickwrap::Event",
             foreign_key: :predecessor_event_id,
             inverse_of: :predecessor_event,
             dependent: :restrict_with_error

    validates :event_type, inclusion: { in: Vocabulary::EVENT_TYPES }
    validates :capture_channel, inclusion: { in: Vocabulary::CAPTURE_CHANNELS }
    validates :attribution_method, inclusion: { in: Vocabulary::ATTRIBUTION_METHODS }
    validates :policy_key, :actor_reference, :recorded_at_by_server, presence: true
    validates :canonical_schema_version, :gem_version, presence: true
    validate :represented_party_has_complete_authority

    before_validation :assign_identifier, on: :create
    before_validation :assign_retention_schedule_from_class, on: :create
    before_create :assign_recording_sequence!
    # Reserve a chain position before INSERTing this event or any autosaved
    # statement/document rows. InnoDB can otherwise deadlock two first writers:
    # each transaction holds evidence-row locks and then both try to create the
    # same previously-absent chain head. Taking the one chain-head lock first
    # gives PostgreSQL and MySQL the same lock order for captures, lifecycle
    # events, and imports.
    before_create :assign_chain_position!
    before_update :refuse_ordinary_update
    before_commit :ensure_integrity_was_finalized, on: :create

    # `prepend: true` matters. The `dependent: :restrict_with_error` callbacks
    # on the associations above are themselves `before_destroy` hooks, and they
    # were registered first, so without prepending they would abort the destroy
    # by returning false — quietly. A caller that does not check the return
    # value would then believe it had deleted evidence. Raising first makes the
    # refusal impossible to miss.
    before_destroy :refuse_destroy, prepend: true

    # Optional integrations run only after the required work has committed, and
    # only ever after it. Registering this as an `after_commit` rather than
    # calling it at the end of the capture matters when Clickwrap joined a
    # host's transaction: at that point the capture has returned but the outer
    # transaction has not committed, and a notification sent from inside a
    # transaction that later rolls back announces something that never happened.
    #
    # A failure here is reported and swallowed. By the time it runs, the
    # evidence and the action it protected are durable, and an analytics outage
    # must not be able to undo them.
    after_commit :at_apparent_commit_boundary, on: :create
    after_rollback :invalidate_pending_receipts_after_rollback!, on: :create

    scope :captures, -> { where(event_type: "capture") }
    scope :human_actions, -> { where(event_type: Vocabulary::HUMAN_ACTION_EVENT_TYPES) }
    scope :for_actor, ->(reference) { where(actor_reference: reference) }
    scope :for_policy, ->(key) { where(policy_key: key.to_s) }
    scope :for_subject_key, ->(key) { where(subject_key: key.to_s) }
    scope :on_hold, -> { where(on_legal_hold: true) }
    scope :not_disposed, -> { where(core_event_disposed_at: nil) }
    # Server timestamps can tie or move backwards, and ULIDs are identifiers,
    # not an ordering protocol. Every event receives one database-generated
    # sequence value, which is the durable total order used by projections,
    # lifecycle exports, and cross-actor `recorded_after?` checks.
    scope :chronological, -> { order(:recording_sequence) }

    scope :due_for_core_disposition, lambda { |at = Clickwrap.now|
      not_disposed.where(on_legal_hold: false).where(retain_core_event_until: ..at)
    }

    # Questions an `after_event_is_committed` hook actually asks. A host wiring
    # up "stop processing when someone withdraws" should not have to know that
    # the answer is a string comparison against an event-type vocabulary.
    def consent_was_withdrawn? = event_type == "withdrawal"
    def consent_was_granted? = capture? && statements.any? { |s| s.kind == "consent" && s.answered? }
    def declaration_was_corrected? = event_type == "correction"
    def authorization_was_consumed? = event_type == "consumption"
    def evidence_was_disposed? = event_type == "disposition"

    # The purposes this event affected, for a hook that needs to know which
    # processing to stop.
    def purpose_keys = statements.filter_map(&:purpose_key).uniq

    def capture? = event_type == "capture"
    def imported? = %w[imported_legacy external_receipt].include?(event_type)
    def exemption? = event_type == "exemption"
    def human_action? = Vocabulary.human_action_event_type?(event_type)
    def disposed? = core_event_disposed_at.present?
    def held? = on_legal_hold?

    def statement(statement_key)
      statements.find { |candidate| candidate.statement_key == statement_key.to_s }
    end

    def policy = Clickwrap.policies[policy_key]

    def compiled_policy_snapshot = policy_revision&.compiled_snapshot

    def receipt = Receipt.new(self)

    # The canonical body this event's digest covers. It deliberately excludes
    # the mutable columns: whether a legal hold is currently in effect, and
    # whether the optional annex has since been disposed of, are facts about
    # today, not about what was recorded. Including them would make an ordinary
    # retention run look like tampering.
    def canonical_body
      {
        "schema" => canonical_schema_version,
        "event_id" => id,
        "event_type" => event_type,
        "policy" => { "key" => policy_key, "revision" => policy_revision&.revision_digest }.compact,
        "actor" => canonical_actor,
        "tenant" => tenant_key,
        "subject" => canonical_subject,
        "capture_channel" => capture_channel,
        "authentication_method" => authentication_method,
        "authentication_context" => authentication_context.presence,
        "recorded_at_by_server" => Receipt.format_time(recorded_at_by_server),
        "occurred_at" => Receipt.format_time(occurred_at),
        "recording_order" => { "database_sequence" => recording_sequence },
        "idempotency_key" => idempotency_key,
        "http_request_id" => http_request_id,
        "http_route_name" => http_route_name,
        "acts" => statements.map(&:canonical_fragment),
        "documents" => documents.map(&:canonical_fragment),
        "presentation" => canonical_presentation,
        "protected_outcome" => protected_outcome.presence,
        "provider" => canonical_provider,
        "request_evidence" => canonical_request_evidence_binding,
        "predecessor_event_id" => predecessor_event_id,
        "root_event_id" => root_event_id,
        "reason" => reason,
        "retention" => {
          "class" => retention_class_key,
          "retain_core_event_until" => Receipt.format_time(retain_core_event_until),
          "rule" => retention_rule_name
        }.compact.presence,
        "chain" => {
          "scope" => chain_scope,
          "sequence" => chain_sequence,
          "previous_event_digest" => previous_event_digest
        }.compact.presence,
        "gem_version" => gem_version,
        "application_version" => application_version,
        "template_version" => template_version,
        "created_at" => Receipt.format_time(created_at)
      }.compact
    end

    def compute_digest
      Digest.digest_canonical(canonical_body, algorithm: digest_algorithm || "sha256")
    end

    # Recomputes the digest and compares it with the one recorded at write time.
    # A false here means the row's meaningful bytes changed since it was
    # written; it does not, on its own, say who changed them or when.
    def digest_verified?
      return false if event_digest.blank?

      Digest.secure_compare?(compute_digest, event_digest)
    end

    # A disposed core payload cannot be recomputed: the point of disposition is
    # that those bytes are gone. Keep that state separate from a verifying
    # digest. A valid, digest-bound disposition event can account for the
    # mismatch, while an unexplained marker or altered row remains a failure.
    def digest_integrity_status
      if disposed?
        return :documented_core_disposition if documented_core_disposition?

        return :unaccounted_mismatch
      end

      return :verified if digest_verified?

      :unaccounted_mismatch
    end

    def digest_integrity_accounted_for?
      digest_integrity_status != :unaccounted_mismatch
    end

    # The optional annex has its own keyed binding. A permitted category
    # disposition makes the original HMAC no longer recomputable; that state is
    # accepted only when every deletion timestamp has a valid linked
    # disposition event naming the category.
    def request_evidence_binding_status
      annex = request_evidence
      digests = request_evidence_category_binding_digests.to_h
      has_binding = digests.present? || request_evidence_key_id.present? ||
                    request_evidence_digest_algorithm.present?

      return :not_recorded if annex.nil? && !has_binding
      return :missing_annex_or_binding if annex.nil? || !has_binding
      return :missing_annex_or_binding unless digests.keys.sort == RequestEvidence::CATEGORIES.map(&:to_s).sort

      return :binding_key_unavailable unless annex.binding_key_available?(request_evidence_key_id)

      disposed = false
      RequestEvidence::CATEGORIES.each do |category|
        if annex.deleted_for?(category)
          disposed = true
          return :undocumented_disposition unless request_evidence_disposition_documented?(annex, category)

          next
        end

        verified = annex.category_binding_digest_verified?(
          category: category,
          digest: digests[category.to_s],
          algorithm: request_evidence_digest_algorithm,
          key_id: request_evidence_key_id
        )
        return :digest_mismatch unless verified
      end

      disposed ? :disposed_with_documented_events : :verified
    rescue ::ActiveRecord::Encryption::Errors::Base
      # Losing or rotating away an encryption key is different from a digest
      # mismatch. The annex cannot currently be read, so verification reports
      # that limited fact instead of crashing or calling the bytes modified.
      :annex_unreadable
    end

    def evidence_integrity_verified?
      digest_verified? && %i[
        not_recorded verified disposed_with_documented_events
      ].include?(request_evidence_binding_status)
    end

    # Finalization is deliberately explicit and happens only after every child
    # statement/document, protected outcome, registration binding, retention
    # decision, and chain position exists. Computing this in `before_create`
    # produced digests for a half-built event and made normal successful
    # captures fail their own integrity check.
    def finalize_integrity!
      raise EventWriteFailed, "Event #{id} has not been persisted, so it cannot be finalized." unless persisted?
      if event_digest.present?
        raise EventWriteFailed,
              "Event #{id} was already finalized and cannot be finalized twice."
      end

      # Normally assigned by the before-create callback so chain contention is
      # the first database lock this event takes. Keep this idempotent call as a
      # defensive invariant for a host that deliberately bypassed callbacks
      # while constructing an internal event.
      assign_chain_position!
      self.event_digest = compute_digest

      update_columns(
        chain_scope: chain_scope,
        chain_sequence: chain_sequence,
        previous_event_digest: previous_event_digest,
        event_digest: event_digest,
        digest_algorithm: digest_algorithm,
        canonical_schema_version: canonical_schema_version
      )

      ChainHead.record!(chain_scope: chain_scope, event_id: id, event_digest: event_digest) if chain_scope.present?
      self
    end

    def track_pending_receipt(pending_receipt)
      (@pending_receipts ||= []) << pending_receipt
      pending_receipt
    end

    # Called only once durable commit is no longer capable of being rolled
    # back. Public because DurableCommitCallback invokes it through Active
    # Record's transaction-record protocol; it is not host application API.
    def finalize_durable_commit!
      commit_pending_receipts
      run_after_commit_hook
      run_integrity_attestors
      self
    end

    def invalidate_pending_receipts_after_rollback!
      Array(@pending_receipts).each(&:mark_rolled_back!)
      self
    end

    # --- The two permitted mutations -----------------------------------------

    # Marks the core event as disposed of under a retention rule. The row stays:
    # what disappears is the payload, and the disposition is itself recorded as
    # a linked event, so an auditor sees a documented deletion rather than a gap.
    def dispose_core_payload!(disposition_event:, at: Clickwrap.now)
      transaction do
        # Mark and link the documented disposition first. The PostgreSQL
        # hardening tier permits child DELETEs only while their parent carries
        # this marker. If any later deletion fails, this transaction rolls the
        # marker back as well, so callers can never observe a half-disposed row.
        update_columns(
          actor_type: nil,
          actor_id: nil,
          actor_reference: "",
          actor_snapshot: {},
          represented_party_type: nil,
          represented_party_id: nil,
          represented_party_reference: "",
          authority_source: nil,
          authority_role: nil,
          authority_verified_at: nil,
          authority_details: {},
          tenant_key: "",
          subject_type: nil,
          subject_id: nil,
          subject_key: "",
          subject_fingerprint: nil,
          authentication_method: nil,
          authentication_context: {},
          idempotency_key: nil,
          http_request_id: nil,
          http_route_name: nil,
          presentation_id: nil,
          presentation_manifest: nil,
          presentation_manifest_digest: nil,
          protected_outcome: nil,
          provider_receipt: nil,
          provider_verification: nil,
          reason: nil,
          core_event_disposed_at: at,
          core_event_disposition_event_id: disposition_event.id
        )

        # Calling `delete_all` through a `has_many` association asks Active
        # Record to null the foreign key. These evidence children have an
        # intentionally non-null foreign key, so issue real, scoped DELETEs.
        EventStatement.where(event_id: id).delete_all
        EventDocument.where(event_id: id).delete_all
        # A root and its later lifecycle events are independently retained
        # evidence payloads. Disposing the root must not erase a projection that
        # now points at a still-retained correction, renewal, withdrawal, or
        # other successor. Remove only projections for which this exact event is
        # current; a later successor removes its own projection when its own
        # schedule becomes due.
        StatementState.where(current_event_id: id).delete_all
      end
      self
    end

    def documented_core_disposition?
      return false unless disposed? && core_event_disposition_event_id.present?

      disposition = Event.find_by(id: core_event_disposition_event_id)
      facts = disposition&.protected_outcome.to_h["core_event_disposition"].to_h
      disposition_event_links_to_self?(disposition) && disposition.digest_verified? &&
        facts["event_id"] == id &&
        facts["original_event_digest"] == event_digest &&
        facts["disposed_at"] == Receipt.format_time(core_event_disposed_at)
    end

    def set_legal_hold!(held)
      update_columns(on_legal_hold: held)
    end

    # Only the foreign key. The binding digest was written when the event was
    # created, because it is part of the canonical body the event digest covers;
    # setting it afterwards would leave every event with request evidence
    # failing its own verification. `request_evidence_id` is safe to set here
    # precisely because it is NOT in the canonical body — it is a pointer, not
    # a fact about what was recorded.
    def attach_request_evidence!(record)
      update_columns(request_evidence_id: record.id)
    end

    def to_s = "#{event_type} #{policy_key} #{id}"

    private

    def assign_identifier
      self.id ||= Identifier.generate(recorded_at_by_server || Clickwrap.now)
      self.canonical_schema_version ||= Clickwrap::CANONICAL_SCHEMA_VERSION
      self.gem_version ||= Clickwrap::VERSION
      self.digest_algorithm ||= Clickwrap.config.digest_canonical_receipts_with.to_s
    end

    # Freeze every event's core-payload schedule when the event is written.
    # Captures, imports, exemptions, and lifecycle events all pass through this
    # callback, so none silently falls back to a retention class that may have
    # changed years later. Each lifecycle event starts from its own
    # `recorded_at_by_server`; disposing a root therefore never implies that a
    # later successor is due too.
    #
    # Disposition events deliberately carry no further disposal schedule. Their
    # small, digest-bound payload is the tombstone that explains why an earlier
    # event no longer has its original body. Disposing that explanation would
    # make the earlier lawful deletion indistinguishable from damage and would
    # create an endless chain of disposition-of-disposition events.
    def assign_retention_schedule_from_class
      return if retention_class_key.blank?
      return if event_type == "disposition"
      return if retain_core_event_until.present? || retention_rule_name.present?

      rule = Clickwrap.retention_class!(retention_class_key).rule_for(:core_event)
      return if rule.nil?

      if rule.duration?
        self.retain_core_event_until = recorded_at_by_server + rule.duration
      else
        self.retention_rule_name = rule.host_event_name.to_s
      end
    end

    # Deliberately built from `actor_reference` alone, not from the polymorphic
    # `actor_type`/`actor_id` columns.
    #
    # Those columns are a convenience pointer at a row that may not always
    # exist: deleting an account nullifies them, by design, because evidence
    # must outlive the account it describes. If the digest covered them, an
    # ordinary account deletion would make every one of that person's events
    # fail verification — a lawful, expected operation looking exactly like
    # tampering. The reference is the stable pseudonymous identity, and a
    # GlobalID already carries the class inside it.
    def canonical_actor
      {
        "reference" => actor_reference,
        "attribution" => {
          "method" => attribution_method,
          "authenticated" => attribution_method == "authenticated_session"
        },
        "snapshot" => actor_snapshot.presence,
        "represented_party" => if represented_party_reference.present?
                                 {
                                   "type" => represented_party_type,
                                   "reference" => represented_party_reference
                                 }.compact
                               end,
        "authority" => {
          "source" => authority_source,
          "role" => authority_role,
          "verified_at" => Receipt.format_time(authority_verified_at),
          "details" => authority_details.presence
        }.compact.presence
      }.compact
    end

    def canonical_subject
      return nil if subject_key.blank?

      { "reference" => subject_key, "fingerprint" => subject_fingerprint }.compact
    end

    def canonical_presentation
      return nil if presentation_manifest_digest.blank?

      {
        "manifest_digest" => presentation_manifest_digest,
        "manifest" => presentation_manifest.presence
      }.compact
    end

    def canonical_provider
      return nil if provider_name.blank?

      {
        "name" => provider_name,
        "event_id" => provider_event_id,
        "receipt" => provider_receipt.presence,
        "verification" => provider_verification.presence
      }.compact
    end

    def canonical_request_evidence_binding
      digests = request_evidence_category_binding_digests.to_h
      return nil if digests.empty?

      {
        "category_digests" => digests,
        "algorithm" => request_evidence_digest_algorithm,
        "key_id" => request_evidence_key_id
      }.compact
    end

    def assign_chain_position!
      return unless Clickwrap.config.chain_event_history_with
      return if chain_scope.present? || chain_sequence.present? || previous_event_digest.present?

      self.chain_scope = [tenant_key.presence || "global", policy_key].join("/")
      self.previous_event_digest, self.chain_sequence = ChainHead.reserve!(chain_scope: chain_scope)
    end

    def assign_recording_sequence!
      self.recording_sequence ||= RecordingSequence.create!.id
    end

    def ensure_integrity_was_finalized
      return if event_digest.present? && digest_verified?

      raise EventWriteFailed,
            "Clickwrap event #{id} reached the commit boundary without a valid finalized digest. " \
            "Every writer must append all covered facts and call `finalize_integrity!` before commit."
    end

    def represented_party_has_complete_authority
      if represented_party_reference.blank?
        facts = [authority_source, authority_role, authority_verified_at, authority_details.presence]
        errors.add(:represented_party_reference, "is missing while authority facts are present") if facts.any?
        return
      end

      missing = {
        authority_source: authority_source,
        authority_role: authority_role,
        authority_verified_at: authority_verified_at
      }.select { |_, value| value.blank? }.keys
      return if missing.empty?

      errors.add(:represented_party_reference, "requires #{missing.join(", ")}")
    end

    def commit_pending_receipts
      Array(@pending_receipts).each(&:mark_committed!)
    end

    def run_after_commit_hook
      Clickwrap.config.after_event_is_committed.call(self)
    rescue StandardError => error
      Clickwrap.report_after_commit_failure(error, self)
    end

    def run_integrity_attestors
      Integrity::Attestor.attest_after_commit(self)
    end

    def at_apparent_commit_boundary
      connection = ::ActiveRecord::Base.connection

      if connection.transaction_open?
        @durable_commit_callback ||= DurableCommitCallback.defer(self)
      else
        finalize_durable_commit!
      end
    end

    def request_evidence_disposition_documented?(annex, category)
      events = Event.where(root_event_id: root_event_id || id, event_type: "disposition").to_a

      events.any? do |candidate|
        disposition = candidate.protected_outcome.to_h["request_evidence_disposition"].to_h
        disposition_event_links_to_self?(candidate) && candidate.digest_verified? &&
          disposition["category"] == category.to_s &&
          disposition["annex_id"].to_s == annex.id.to_s &&
          disposition["disposed_at"].to_s == Receipt.format_time(annex.public_send(:"#{category}_deleted_at"))
      end
    end

    def disposition_event_links_to_self?(candidate)
      candidate&.event_type == "disposition" &&
        candidate.predecessor_event_id.to_s == id.to_s &&
        candidate.root_event_id.to_s == (root_event_id.presence || id).to_s
    end

    def refuse_ordinary_update
      touched = changed - MUTABLE_COLUMNS
      return if touched.empty?

      raise EventWriteFailed,
            "Clickwrap events refuse ordinary mutation, so #{touched.join(", ")} cannot be updated on " \
            "event #{id}. Corrections, withdrawals, expiries, and supersessions are new linked " \
            "events; that is what keeps a receipt able to show what was true at the time as " \
            "well as what is true now."
    end

    def refuse_destroy
      raise EventWriteFailed,
            "Clickwrap events cannot be destroyed through the ordinary model API. Event #{id} " \
            "must remain at its chain position. Disposition " \
            "runs through Clickwrap::Retention with a reason and its own recorded event."
    end
  end
end
