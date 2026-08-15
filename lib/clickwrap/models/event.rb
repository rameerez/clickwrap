# frozen_string_literal: true

module Clickwrap
  # One immutable evidence event.
  #
  # A capture, a withdrawal, a correction, an expiry, a consumption, a
  # disposition, a hold — each is a row here, linked to what it acts on. The
  # table is append-only, and this class enforces that rather than trusting
  # everyone who ever writes application code against it: `update` and `destroy`
  # raise, and the two legitimate mutations (marking the core event disposed,
  # flagging a legal hold) go through named methods that append their own event
  # explaining what happened and why.
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

    MUTABLE_COLUMNS = %w[core_event_disposed_at on_legal_hold request_evidence_id].freeze

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

    before_validation :assign_identifier, on: :create
    before_create :assign_digest

    before_update :refuse_ordinary_update

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
    after_commit :run_after_commit_hook, on: :create

    scope :captures, -> { where(event_type: "capture") }
    scope :human_actions, -> { where(event_type: Vocabulary::HUMAN_ACTION_EVENT_TYPES) }
    scope :for_actor, ->(reference) { where(actor_reference: reference) }
    scope :for_policy, ->(key) { where(policy_key: key.to_s) }
    scope :for_subject_key, ->(key) { where(subject_key: key.to_s) }
    scope :on_hold, -> { where(on_legal_hold: true) }
    scope :not_disposed, -> { where(core_event_disposed_at: nil) }
    scope :chronological, -> { order(:recorded_at_by_server, :id) }

    scope :due_for_core_disposition, lambda { |at = Clickwrap.now|
      not_disposed.where(on_legal_hold: false).where(retain_core_event_until: ...at)
    }

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
        "recorded_at_by_server" => Receipt.format_time(recorded_at_by_server),
        "occurred_at" => Receipt.format_time(occurred_at),
        "idempotency_key" => idempotency_key,
        "http_request_id" => http_request_id,
        "acts" => statements.map(&:canonical_fragment),
        "documents" => documents.map(&:canonical_fragment),
        "presentation" => canonical_presentation,
        "protected_outcome" => protected_outcome.presence,
        "provider" => canonical_provider,
        "request_evidence_digest" => request_evidence_digest,
        "predecessor_event_id" => predecessor_event_id,
        "root_event_id" => root_event_id,
        "reason" => reason,
        "gem_version" => gem_version,
        "application_version" => application_version
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

    # --- The two permitted mutations -----------------------------------------

    # Marks the core event as disposed of under a retention rule. The row stays:
    # what disappears is the payload, and the disposition is itself recorded as
    # a linked event, so an auditor sees a documented deletion rather than a gap.
    def mark_core_event_disposed!(at: Clickwrap.now)
      update_columns(core_event_disposed_at: at) # rubocop:disable Rails/SkipsModelValidations
    end

    def set_legal_hold!(held)
      update_columns(on_legal_hold: held) # rubocop:disable Rails/SkipsModelValidations
    end

    # Only the foreign key. The binding digest was written when the event was
    # created, because it is part of the canonical body the event digest covers;
    # setting it afterwards would leave every event with request evidence
    # failing its own verification. `request_evidence_id` is safe to set here
    # precisely because it is NOT in the canonical body — it is a pointer, not
    # a fact about what was recorded.
    def attach_request_evidence!(record)
      update_columns(request_evidence_id: record.id) # rubocop:disable Rails/SkipsModelValidations
    end

    def to_s = "#{event_type} #{policy_key} #{id}"

    private

    def assign_identifier
      self.id ||= Identifier.generate(recorded_at_by_server || Clickwrap.now)
      self.canonical_schema_version ||= Clickwrap::CANONICAL_SCHEMA_VERSION
      self.gem_version ||= Clickwrap::VERSION
      self.digest_algorithm ||= Clickwrap.config.digest_canonical_receipts_with.to_s
    end

    def assign_digest
      self.event_digest = compute_digest
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
        "represented_party" => represented_party_reference,
        "authority" => { "source" => authority_source, "role" => authority_role }.compact.presence
      }.compact
    end

    def represented_party_reference
      return nil if represented_party_type.blank?

      "#{represented_party_type}/#{represented_party_id}"
    end

    def canonical_subject
      return nil if subject_key.blank?

      { "reference" => subject_key, "fingerprint" => subject_fingerprint }.compact
    end

    def canonical_presentation
      return nil if presentation_manifest_digest.blank?

      {
        "manifest_digest" => presentation_manifest_digest,
        "submit_button_text" => presentation_manifest&.dig("submit_button_text"),
        "offered_at" => presentation_manifest&.dig("issued_at")
      }.compact
    end

    def canonical_provider
      return nil if provider_name.blank?

      {
        "name" => provider_name,
        "event_id" => provider_event_id,
        "verification" => provider_verification.presence
      }.compact
    end

    def run_after_commit_hook
      Clickwrap.config.after_event_is_committed.call(self)
    rescue StandardError => e
      Clickwrap.report_after_commit_failure(e, self)
    end

    def refuse_ordinary_update
      touched = changed - MUTABLE_COLUMNS
      return if touched.empty?

      raise EventWriteFailed,
            "Clickwrap events are append-only, so #{touched.join(', ')} cannot be updated on " \
            "event #{id}. Corrections, withdrawals, expiries, and supersessions are new linked " \
            "events; that is what keeps a receipt able to show what was true at the time as " \
            "well as what is true now."
    end

    def refuse_destroy
      raise EventWriteFailed,
            "Clickwrap events are append-only, so event #{id} cannot be destroyed. Disposition " \
            "runs through Clickwrap::Retention with a reason and its own recorded event."
    end
  end
end
