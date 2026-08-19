# frozen_string_literal: true

# CONCRETE rendering of lib/generators/clickwrap/templates/create_clickwrap_tables.rb.erb.
#
# This is the SAME migration the install generator copies into a real host,
# rendered to plain Ruby for the dummy app's test database. It is run by
# `rake db:migrate:reset` across all three CI database legs (sqlite / postgres
# / mysql), so the private helpers at the bottom are kept IDENTICAL to the
# template's: they branch on the connection adapter to emit jsonb-vs-json,
# MySQL's no-default-on-JSON caveat, and MEDIUMTEXT for document bodies.
#
# KEEP IN SYNC with the ERB template. test/generators/install_generator_test.rb
# carries a drift test that compares the two, per tier, and fails the build the
# moment they disagree — so "the migration the dummy proved" and "the migration
# users get" can never diverge silently.
#
# The dummy installs EVERY tier, because the suite exercises every capability.
# A default install emits only the first of these files.
#
# The migration version is pinned to [7.1] — the gemspec floor and the lowest
# Rails in the test matrix.

class CreateClickwrapTables < ActiveRecord::Migration[7.1]
  def change
    primary_key_type, foreign_key_type = primary_and_foreign_key_types

    # ---------------------------------------------------------------------------
    # clickwrap_documents / clickwrap_document_versions
    #
    # A logical document (:terms) is separate from its immutable versions,
    # because that separation is what lets a receipt from 2026 still show the
    # exact bytes bound into an accepted server offer after the file on disk has
    # changed a dozen times. Publishing freezes `content` and its digest; a change means a new
    # version row, never an UPDATE. `retired_at` stops future presentation
    # without touching history.
    #
    # `rendered_content` exists because "this Markdown file existed" and "this
    # rendered representation was offered" are different claims. When a source
    # format is transformed for display we store both, with the renderer and
    # sanitizer identity that produced it, so neither claim borrows the other's
    # credibility.
    # ---------------------------------------------------------------------------
    create_table :clickwrap_documents, id: primary_key_type do |t|
      t.string :document_key, null: false
      t.string :tenant_key
      t.datetime :created_at, precision: 6, null: false
    end

    add_index :clickwrap_documents, [ :tenant_key, :document_key ],
              unique: true, name: "index_clickwrap_documents_on_tenant_and_key"

    create_table :clickwrap_document_versions, id: primary_key_type do |t|
      t.references :document, null: false, type: foreign_key_type, index: false,
                              foreign_key: { to_table: :clickwrap_documents }

      t.string :version_label, null: false
      t.string :locale, null: false, default: "en"
      t.string :media_type, null: false, default: "text/plain"

      t.send(text_column_type, :content)
      t.bigint :content_byte_size
      t.string :content_digest_algorithm, null: false, default: "sha256"
      t.string :content_digest, null: false

      t.send(text_column_type, :rendered_content)
      t.string :rendered_media_type
      t.string :rendered_content_digest
      t.string :renderer_name
      t.string :renderer_version
      t.string :sanitizer_name
      t.string :sanitizer_version

      # Where the bytes live. `database` is the default and the only one that
      # needs nothing else to stay readable; the others record a locator whose
      # adapter must still return immutable bytes plus a verifiable digest.
      t.string :storage_backend, null: false, default: "database"
      t.string :storage_locator
      t.string :source_reference

      t.datetime :effective_at, precision: 6
      t.datetime :published_at, precision: 6
      t.datetime :retired_at, precision: 6
      t.string :retired_reason

      t.datetime :created_at, precision: 6, null: false
    end

    add_index :clickwrap_document_versions, [ :document_id, :version_label, :locale ],
              unique: true, name: "index_clickwrap_document_versions_on_identity"
    add_index :clickwrap_document_versions, :content_digest,
              name: "index_clickwrap_document_versions_on_content_digest"

    # ---------------------------------------------------------------------------
    # clickwrap_policy_revisions
    #
    # Policies are written in Ruby, because that is reviewable in a pull request
    # and deploys with the code. But an export must stay intelligible after the
    # source has moved on, so the compiled snapshot is frozen here the first time
    # a revision is offered or captured. The revision digest is the identity:
    # change a statement's wording and you get a new revision, and old events go
    # on pointing at the one they were captured under.
    # ---------------------------------------------------------------------------
    create_table :clickwrap_policy_revisions, id: primary_key_type do |t|
      t.string :policy_key, null: false
      t.string :revision_digest, null: false
      t.send(json_column_type, :compiled_snapshot, null: false)
      t.string :retention_class_key
      t.string :canonical_schema_version, null: false
      t.string :gem_version, null: false
      t.datetime :compiled_at, precision: 6, null: false
      t.datetime :created_at, precision: 6, null: false
    end

    add_index :clickwrap_policy_revisions, [ :policy_key, :revision_digest ],
              unique: true, name: "index_clickwrap_policy_revisions_on_identity"

    # ---------------------------------------------------------------------------
    # clickwrap_events
    #
    # The append-oriented spine. Every act, correction, withdrawal, expiry,
    # consumption, disposition, and hold is a row here, linked to what came
    # before. Ordinary model updates are refused; fixed write sets exist for
    # finalization, pointer nullification, annex links, holds, and reviewed
    # disposition. There is no generic `updated_at` column that could obscure
    # which named transition occurred.
    #
    # The public primary key is a ULID string: it appears verbatim in receipts
    # without exposing a count of unrelated records. Chronology never relies on
    # lexical ULID order. A separate database-generated sequence gives committed
    # events one durable total order across actors and application processes.
    #
    # `recorded_at_by_server` is the evidentiary time, and it is named for
    # exactly what it is: the application server's clock. `occurred_at` is
    # separate and only set by importers, which know when something happened but
    # were not there for it.
    # ---------------------------------------------------------------------------
    # Intentionally only the generated primary key: this row is ordering
    # machinery, not a second event timestamp or a second evidence payload.
    # This one table deliberately does NOT inherit a UUID host application's
    # default primary-key type. Its generated numeric key is the private total
    # order referenced by `clickwrap_events.recording_sequence`; the public
    # event identifier remains the non-enumerable ULID.
    create_table :clickwrap_recording_sequences, id: :primary_key do |_t|
    end

    create_table :clickwrap_events, id: :string, limit: 26 do |t|
      t.string :event_type, null: false
      t.string :policy_key, null: false
      t.references :policy_revision, null: true, type: foreign_key_type, index: false,
                                     foreign_key: { to_table: :clickwrap_policy_revisions }

      # Lifecycle links. `root_event_id` points at the capture a later event
      # acts on; `predecessor_event_id` points at the event it directly
      # replaces. Correction, withdrawal, expiry, consumption and supersession
      # all create linked rows — they never rewrite what they succeed.
      t.string :root_event_id, limit: 26
      t.string :predecessor_event_id, limit: 26

      t.string :actor_type
      t.string :actor_id
      t.string :actor_reference, null: false
      t.send(json_column_type, :actor_snapshot, default: json_column_default)

      # Who the actor was acting for, kept as a separate fact from who they are.
      t.string :represented_party_type
      t.string :represented_party_id
      t.string :represented_party_reference, null: false, default: ""
      t.string :authority_source
      t.string :authority_role
      t.datetime :authority_verified_at, precision: 6
      t.send(json_column_type, :authority_details, default: json_column_default)

      t.string :tenant_key
      t.string :subject_type
      t.string :subject_id
      t.string :subject_key, null: false, default: ""
      t.string :subject_fingerprint

      t.string :capture_channel, null: false
      t.string :authentication_method
      t.send(json_column_type, :authentication_context, default: json_column_default)
      t.string :attribution_method, null: false, default: "unknown"

      t.datetime :recorded_at_by_server, precision: 6, null: false
      t.datetime :occurred_at, precision: 6
      t.bigint :recording_sequence, null: false

      t.string :idempotency_key
      t.string :http_request_id
      t.string :http_route_name

      # The column is always here; the foreign key arrives with the table, in
      # the --with-persisted-presentations migration. A default install writes
      # nothing on GET, so it has nothing for this column to point at.
      t.references :presentation, null: true, type: foreign_key_type, index: false
      t.send(json_column_type, :presentation_manifest)
      t.string :presentation_manifest_digest

      # The optional personal request evidence lives in its own table so it can
      # be deleted on its own schedule without rewriting this row. What stays
      # here is a keyed digest binding the two together — described honestly as
      # a retained linkable digest, never as anonymization.
      t.references :request_evidence, null: true, type: foreign_key_type, index: false
      t.send(json_column_type, :request_evidence_category_binding_digests,
             null: false, default: json_column_default)
      t.string :request_evidence_digest_algorithm
      t.string :request_evidence_key_id

      t.send(json_column_type, :protected_outcome)

      t.string :provider_name
      t.string :provider_event_id
      t.send(json_column_type, :provider_receipt)
      t.send(json_column_type, :provider_verification)

      t.text :reason

      t.string :retention_class_key
      t.datetime :retain_core_event_until, precision: 6
      t.string :retention_rule_name
      t.datetime :core_event_disposed_at, precision: 6
      t.string :core_event_disposition_event_id, limit: 26
      t.boolean :on_legal_hold, null: false, default: false

      t.string :chain_scope
      t.bigint :chain_sequence
      t.string :previous_event_digest
      t.string :event_digest
      t.string :digest_algorithm, null: false, default: "sha256"
      t.string :canonical_schema_version, null: false

      t.string :gem_version, null: false
      t.string :application_version
      t.string :template_version

      t.datetime :created_at, precision: 6, null: false
    end

    # The idempotency guarantee is a database constraint, not application logic:
    # a duplicate submit loses the INSERT race and gets the original receipt
    # back rather than running the protected action a second time.
    add_index :clickwrap_events, [ :policy_key, :idempotency_key ],
              unique: true, name: "index_clickwrap_events_on_idempotency_key"
    add_index :clickwrap_events, [ :chain_scope, :chain_sequence ],
              unique: true, name: "index_clickwrap_events_on_chain_position"
    add_index :clickwrap_events, :recording_sequence,
              unique: true, name: "index_clickwrap_events_on_recording_order"
    add_foreign_key :clickwrap_events, :clickwrap_recording_sequences,
                    column: :recording_sequence
    add_index :clickwrap_events, [ :actor_reference, :policy_key ],
              name: "index_clickwrap_events_on_actor_and_policy"
    add_index :clickwrap_events, [ :subject_type, :subject_id ],
              name: "index_clickwrap_events_on_subject"
    add_index :clickwrap_events, :root_event_id, name: "index_clickwrap_events_on_root_event"
    add_index :clickwrap_events, :predecessor_event_id,
              name: "index_clickwrap_events_on_predecessor_event"
    add_index :clickwrap_events, :presentation_id,
              name: "index_clickwrap_events_on_presentation"
    add_index :clickwrap_events, :request_evidence_id, unique: true,
              name: "index_clickwrap_events_on_request_evidence"
    add_index :clickwrap_events, :core_event_disposition_event_id,
              name: "index_clickwrap_events_on_core_disposition"
    add_index :clickwrap_events, :recorded_at_by_server,
              name: "index_clickwrap_events_on_recorded_at_by_server"
    add_index :clickwrap_events, :retain_core_event_until,
              name: "index_clickwrap_events_on_retain_core_event_until"
    add_index :clickwrap_events, :retention_class_key,
              name: "index_clickwrap_events_on_retention_class_key"
    add_index :clickwrap_events, :subject_key,
              name: "index_clickwrap_events_on_subject_key"
    add_clickwrap_check_constraint :clickwrap_events,
                         "event_type IN (#{quoted_values(%w[capture withdrawal correction supersession expiry consumption revocation renewal scope_change exemption imported_legacy external_receipt disposition legal_hold_placed legal_hold_released receipt_access provider_outcome])})",
                         name: "chk_clickwrap_events_event_type"
    add_clickwrap_check_constraint :clickwrap_events,
                         "capture_channel IN (#{quoted_values(%w[web_browser native_app api_client operator background_job imported_provider system])})",
                         name: "chk_clickwrap_events_channel"
    add_clickwrap_check_constraint :clickwrap_events,
                         "attribution_method IN (#{quoted_values(%w[authenticated_session account_registration public_form operator_session api_credential anonymous_identifier system_process imported_provider unknown])})",
                         name: "chk_clickwrap_events_attribution"

    # ---------------------------------------------------------------------------
    # clickwrap_event_statements
    #
    # One row per act inside a capture. A policy with "agree to the Terms" and
    # "acknowledge the Privacy Notice" produces one event and two rows here, and
    # they never merge: each keeps its own kind, its own assertion text as it was
    # resolved into the accepted server offer, its own answer, and its own validity.
    #
    # These rows are immutable snapshots. Current state lives in the projection
    # table below, which can be rebuilt from these at any time.
    # ---------------------------------------------------------------------------
    create_table :clickwrap_event_statements, id: primary_key_type do |t|
      t.string :event_id, limit: 26, null: false
      t.integer :ordinal, null: false, default: 0

      t.string :statement_key, null: false
      t.string :kind, null: false
      t.string :action, null: false

      t.text :assertion_text, null: false
      t.string :assertion_locale, null: false
      t.text :label_text
      t.send(json_column_type, :link_labels, default: json_column_default)
      t.send(json_column_type, :choices)

      t.boolean :required, null: false, default: true
      t.boolean :optional, null: false, default: false
      t.send(json_column_type, :answer)
      t.boolean :answered, null: false, default: false

      t.string :purpose_key
      t.string :withdrawal_path

      t.datetime :valid_from, precision: 6
      t.datetime :expires_at, precision: 6
      t.boolean :one_time, null: false, default: false
      t.send(json_column_type, :requires, default: json_array_default)

      t.string :subject_fingerprint

      t.datetime :created_at, precision: 6, null: false
    end

    add_index :clickwrap_event_statements, [ :event_id, :statement_key ],
              unique: true, name: "index_clickwrap_event_statements_on_identity"
    add_index :clickwrap_event_statements, [ :kind, :statement_key ],
              name: "index_clickwrap_event_statements_on_kind_and_key"
    add_clickwrap_check_constraint :clickwrap_event_statements,
                         "kind IN (#{quoted_values(%w[agreement acknowledgment consent declaration attestation authorization])})",
                         name: "chk_clickwrap_statements_kind"
    add_clickwrap_check_constraint :clickwrap_event_statements,
                         "action IN (#{quoted_values(%w[agreed superseded acknowledged expired granted declined withdrawn renewed scope_changed declared corrected attested authorized consumed revoked])})",
                         name: "chk_clickwrap_statements_action"
    # Captured controls are required XOR optional. System lifecycle statements
    # describe a transition and are therefore neither; no statement may be both.
    add_clickwrap_check_constraint :clickwrap_event_statements, "NOT (required AND optional)",
                         name: "chk_clickwrap_statements_requirement"

    # ---------------------------------------------------------------------------
    # clickwrap_event_documents
    #
    # Exactly which document versions were bound to which statement, with the
    # digests as they stood at capture. Verification recomputes them, so a
    # document row edited in place is detected rather than believed.
    # ---------------------------------------------------------------------------
    create_table :clickwrap_event_documents, id: primary_key_type do |t|
      t.string :event_id, limit: 26, null: false
      t.string :statement_key, null: false
      t.string :document_key, null: false
      t.references :document_version, null: true, type: foreign_key_type, index: false,
                                      foreign_key: { to_table: :clickwrap_document_versions }

      t.string :version_label, null: false
      t.string :locale, null: false
      t.string :source_media_type
      t.string :source_content_digest, null: false
      t.string :rendered_media_type, null: false
      t.string :rendered_content_digest
      t.string :renderer_name
      t.string :renderer_version
      t.string :sanitizer_name
      t.string :sanitizer_version
      t.integer :ordinal, null: false, default: 0

      t.datetime :created_at, precision: 6, null: false
    end

    add_index :clickwrap_event_documents, [ :event_id, :statement_key, :document_key ],
              unique: true, name: "index_clickwrap_event_documents_on_identity"

    # ---------------------------------------------------------------------------
    # clickwrap_statement_states
    #
    # The current-state projection: the answer to "does this person currently
    # have X?" without walking the whole event history on every request. It is a
    # cache of a computation over retained event payloads and can be rebuilt
    # while the identity-bearing root payloads remain available.
    #
    # The unique index is doing real work: it is what stops two concurrent
    # submits from producing two live grants or two usable authorizations for
    # the same actor and subject. The `_key` columns exist for that index —
    # NULLs do not collide in a unique index on most adapters, so the empty
    # string stands in for "no tenant" and "no subject".
    # ---------------------------------------------------------------------------
    create_table :clickwrap_statement_states, id: primary_key_type do |t|
      # A digest of the six identity columns below, carrying the unique index.
      #
      # This is a portability decision with teeth. Those six hold a policy key,
      # a statement key, a GlobalID-shaped actor reference, a tenant key, a
      # subject key, and a represented-party reference; indexing the strings
      # directly can exceed MySQL's 3072-byte index limit
      # under utf8mb4 even at a reduced length, so a composite unique index over
      # them cannot be created there at all. The guarantee this index provides is
      # the one that keeps a double submit from becoming two debits, so it has to
      # exist on every supported database — hence one fixed-width column, with an
      # ordinary lookup index over the readable ones beside it.
      t.string :identity_digest, null: false, limit: 71

      t.string :policy_key, null: false
      t.string :statement_key, null: false
      t.string :kind, null: false
      t.string :purpose_key

      t.string :actor_type
      t.string :actor_id
      t.string :actor_reference, null: false
      t.string :tenant_key, null: false, default: ""
      t.string :subject_type
      t.string :subject_id
      t.string :subject_key, null: false, default: ""
      t.string :represented_party_reference, null: false, default: ""
      t.string :subject_fingerprint

      t.string :state, null: false
      t.string :current_action, null: false
      t.string :current_event_id, limit: 26, null: false
      t.string :root_event_id, limit: 26
      t.references :policy_revision, null: true, type: foreign_key_type, index: false,
                                     foreign_key: { to_table: :clickwrap_policy_revisions }

      t.datetime :effective_at, precision: 6, null: false
      t.datetime :expires_at, precision: 6
      t.datetime :withdrawn_at, precision: 6
      t.datetime :superseded_at, precision: 6
      t.datetime :consumed_at, precision: 6
      t.datetime :revoked_at, precision: 6
      t.datetime :corrected_at, precision: 6
      t.boolean :one_time, null: false, default: false

      t.send(json_column_type, :document_version_ids, default: json_array_default)

      t.timestamps precision: 6
    end

    add_index :clickwrap_statement_states, :identity_digest,
              unique: true, name: "index_clickwrap_statement_states_on_identity"
    add_index :clickwrap_statement_states,
              [ :policy_key, :statement_key ],
              name: "index_clickwrap_statement_states_on_policy_and_statement"
    add_index :clickwrap_statement_states, [ :actor_reference, :state ],
              name: "index_clickwrap_statement_states_on_actor_and_state"
    add_index :clickwrap_statement_states, :expires_at,
              name: "index_clickwrap_statement_states_on_expires_at"
    add_index :clickwrap_statement_states, :current_event_id,
              name: "index_clickwrap_statement_states_on_current_event"
    add_index :clickwrap_statement_states, :root_event_id,
              name: "index_clickwrap_statement_states_on_root_event"
    add_clickwrap_check_constraint :clickwrap_statement_states,
                         "state IN (#{quoted_values(%w[active declined withdrawn expired superseded consumed revoked corrected exempted])})",
                         name: "chk_clickwrap_states_state"

    # A row exists before or after the first StatementState for an identity, so
    # concurrent first-time authorizations have something portable to lock.
    # These are coordination rows, not evidence, and contain only the canonical
    # identity digest already used by StatementState's unique index.
    create_table :clickwrap_statement_identity_locks, id: primary_key_type do |t|
      t.string :identity_digest, null: false, limit: 71
      t.datetime :created_at, precision: 6, null: false
    end

    add_index :clickwrap_statement_identity_locks, :identity_digest, unique: true,
              name: "index_clickwrap_statement_identity_locks_on_identity"

    # ---------------------------------------------------------------------------
    # clickwrap_receipt_accesses
    #
    # Who read what, and why. Unredacted request evidence needs host
    # authorization plus a human-readable reason, and asking for it appends a
    # row here. An access log that nobody can read is not much of a control, so
    # this table is plain and queryable.
    # ---------------------------------------------------------------------------
    create_table :clickwrap_receipt_accesses, id: primary_key_type do |t|
      t.string :event_id, limit: 26, null: false
      t.string :requested_by_reference
      t.text :reason
      t.send(json_column_type, :included_fields, null: false)
      t.string :access_channel, null: false, default: "api"
      t.datetime :accessed_at, precision: 6, null: false
      t.datetime :created_at, precision: 6, null: false
    end

    add_index :clickwrap_receipt_accesses, [ :event_id, :accessed_at ],
              name: "index_clickwrap_receipt_accesses_on_event"

    # Every non-polymorphic evidence link is backed by the database, including
    # lifecycle links and the tables whose ids are ULID strings rather than the
    # host application's primary-key type. Model callbacks make ordinary writes
    # readable; these constraints keep console SQL, bulk imports, and future code
    # from manufacturing orphaned evidence by accident.
    add_clickwrap_foreign_key :clickwrap_events, :clickwrap_events,
                    column: :root_event_id, name: "fk_clickwrap_events_root"
    add_clickwrap_foreign_key :clickwrap_events, :clickwrap_events,
                    column: :predecessor_event_id, name: "fk_clickwrap_events_predecessor"
    add_clickwrap_foreign_key :clickwrap_events, :clickwrap_events,
                    column: :core_event_disposition_event_id, name: "fk_clickwrap_events_disposition"

    add_clickwrap_foreign_key :clickwrap_event_statements, :clickwrap_events,
                    column: :event_id, name: "fk_clickwrap_statements_event"
    add_clickwrap_foreign_key :clickwrap_event_documents, :clickwrap_events,
                    column: :event_id, name: "fk_clickwrap_documents_event"
    add_clickwrap_foreign_key :clickwrap_statement_states, :clickwrap_events,
                    column: :current_event_id, name: "fk_clickwrap_states_current_event"
    add_clickwrap_foreign_key :clickwrap_statement_states, :clickwrap_events,
                    column: :root_event_id, name: "fk_clickwrap_states_root_event"
    add_clickwrap_foreign_key :clickwrap_receipt_accesses, :clickwrap_events,
                    column: :event_id, name: "fk_clickwrap_receipt_accesses_event"

    # The database rejects contradictory statement requirement flags and values
    # outside this release's frozen vocabularies. A future release that adds a
    # lifecycle value ships an upgrade migration that widens the matching check;
    # raw SQL must not be able to manufacture evidence the model cannot read.
  end

  private

  # Honor the host's configured primary key type (uuid vs bigint). Reads the
  # same setting `rails g model` uses, so an app generated with
  # `config.generators { |g| g.orm :active_record, primary_key_type: :uuid }`
  # gets uuid clickwrap tables and uuid foreign keys, automatically.
  #
  # Note that clickwrap_events keeps a ULID string key regardless: its id is
  # quoted verbatim in receipts and exports, so it has to be stable, sortable,
  # and identical in every host.
  def primary_and_foreign_key_types
    config = Rails.configuration.generators
    setting = config.options[config.orm][:primary_key_type]
    primary_key_type = setting || :primary_key
    foreign_key_type = setting || :bigint
    [ primary_key_type, foreign_key_type ]
  end

  def json_column_type
    return :jsonb if connection.adapter_name.downcase.match?(/postg/) # postgresql, postgis

    :json
  end

  # MySQL 8+ doesn't allow default values on JSON columns. Returns an empty-hash
  # default for SQLite/PostgreSQL, nil for MySQL. The models handle nil
  # gracefully by defaulting to {} in their accessors.
  def json_column_default
    return nil if connection.adapter_name.downcase.match?(/mysql|trilogy/)

    {}
  end

  # Same MySQL caveat as `json_column_default`, but for list-shaped columns.
  def json_array_default
    return nil if connection.adapter_name.downcase.match?(/mysql|trilogy/)

    []
  end

  # Legal documents are routinely longer than MySQL's 64 KB TEXT limit, and a
  # silently truncated agreement is the worst possible failure for this gem.
  # `:mediumtext` maps to MEDIUMTEXT on MySQL (16 MB) and to ordinary TEXT
  # everywhere else.
  def text_column_type
    return :mediumtext if connection.adapter_name.downcase.match?(/mysql|trilogy/)

    :text
  end

  def quoted_values(values)
    values.map { |value| connection.quote(value) }.join(", ")
  end

  # SQLite implements both foreign keys and check constraints by rebuilding a
  # table. During a long install migration, Active Record can otherwise rebuild
  # from a schema-cache entry captured before the indexes/columns immediately
  # above were added. Refreshing around every rebuild keeps the SQLite result
  # identical to PostgreSQL/MySQL instead of quietly resurrecting stale shape.
  def add_clickwrap_check_constraint(table, expression, **options)
    refresh_clickwrap_table_schema!(table)
    add_check_constraint(table, expression, **options)
    refresh_clickwrap_table_schema!(table)
  end

  def add_clickwrap_foreign_key(from_table, to_table, **options)
    refresh_clickwrap_table_schema!(from_table)
    add_foreign_key(from_table, to_table, **options)
    refresh_clickwrap_table_schema!(from_table)
  end

  def refresh_clickwrap_table_schema!(table)
    connection.schema_cache.clear_data_source_cache!(table.to_s)
  end
end