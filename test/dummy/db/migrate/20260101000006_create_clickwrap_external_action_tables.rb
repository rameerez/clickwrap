# frozen_string_literal: true

# CONCRETE rendering of lib/generators/clickwrap/templates/create_clickwrap_external_action_tables.rb.erb.
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

# The external-action outbox — `rails generate clickwrap:install
# --with-external-actions`, or added later with the same command.
#
# Only `Clickwrap.authorize_external_action!` writes here, so an
# application that never crosses a system boundary inside a capture can
# never put a row in this table.
class CreateClickwrapExternalActionTables < ActiveRecord::Migration[7.1]
  def change
    primary_key_type, = primary_and_foreign_key_types

    # ---------------------------------------------------------------------------
    # clickwrap_external_actions
    #
    # The outbox. A provider cannot join your database transaction, so an
    # external handoff gets a pending authorization committed locally, an
    # idempotency key, and an explicit resolution — succeeded, failed, or
    # genuinely unknown. `unknown` is a first-class state because a timeout is
    # not a failure, and treating it as one is how a second debit happens.
    # ---------------------------------------------------------------------------
    create_table :clickwrap_external_actions, id: primary_key_type do |t|
      t.string :event_id, limit: 26, null: false
      t.string :policy_key, null: false
      t.string :idempotency_key, null: false
      t.string :provider_name

      t.string :state, null: false, default: "pending"
      t.integer :attempt_count, null: false, default: 0
      t.send(json_column_type, :provider_receipt)
      t.text :failure_reason

      t.datetime :requested_at, precision: 6, null: false
      t.datetime :resolved_at, precision: 6

      t.timestamps precision: 6
    end

    add_index :clickwrap_external_actions, :idempotency_key, unique: true,
              name: "index_clickwrap_external_actions_on_idempotency_key"
    add_index :clickwrap_external_actions, :event_id, unique: true,
              name: "index_clickwrap_external_actions_on_event"
    add_index :clickwrap_external_actions, [ :state, :requested_at ],
              name: "index_clickwrap_external_actions_on_state"
    add_clickwrap_check_constraint :clickwrap_external_actions,
                         "state IN (#{quoted_values(%w[pending succeeded failed unknown])})",
                         name: "chk_clickwrap_external_actions_state"


    add_clickwrap_foreign_key :clickwrap_external_actions, :clickwrap_events,
                    column: :event_id, name: "fk_clickwrap_external_actions_event"
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