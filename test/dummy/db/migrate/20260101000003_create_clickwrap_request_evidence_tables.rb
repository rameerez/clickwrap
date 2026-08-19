# frozen_string_literal: true

# CONCRETE rendering of lib/generators/clickwrap/templates/create_clickwrap_request_evidence_tables.rb.erb.
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

# The optional request-evidence annex — `rails generate clickwrap:install
# --with-request-evidence`, or added later with the same command.
#
# Nothing personal is recorded until a policy names a field with a purpose
# and a deletion rule, so on a default install this table can never receive
# a row. It ships separately for the same reason the fields are off: an
# application's schema should not imply it collects things it does not.
class CreateClickwrapRequestEvidenceTables < ActiveRecord::Migration[7.1]
  def change
    primary_key_type, = primary_and_foreign_key_types

    # ---------------------------------------------------------------------------
    # clickwrap_request_evidence
    #
    # The optional annex: IP address, browser user-agent, and provider-estimated
    # IP geolocation, none of it recorded unless a policy names the field.
    #
    # It is a separate table on purpose. Personal request evidence needs its own
    # deletion schedule, and welding it into the core event payload would make a
    # lawful deletion request either impossible or destructive of the historical
    # record. Here it can be removed on its own clock while the agreement it
    # accompanied stays intact and verifiable.
    #
    # Every IP-geolocation value carries its provenance in the same row.
    # Coordinates without an accuracy radius, or a country without knowing which
    # provider guessed it, would read as far more certain than they are.
    # ---------------------------------------------------------------------------
    create_table :clickwrap_request_evidence, id: primary_key_type do |t|
      t.string :event_id, limit: 26, null: false
      t.send(json_column_type, :authorized_fields, null: false)

      t.text :ip_address_ciphertext
      t.string :ip_address_reader_name
      t.string :trusted_proxy_configuration_digest
      t.datetime :ip_address_recorded_at, precision: 6
      t.datetime :ip_address_delete_after, precision: 6
      t.string :ip_address_retain_until_rule
      t.datetime :ip_address_deleted_at, precision: 6
      t.string :ip_address_unavailable_reason

      t.text :browser_user_agent_ciphertext
      t.boolean :browser_user_agent_was_client_supplied, null: false, default: true
      t.datetime :browser_user_agent_recorded_at, precision: 6
      t.datetime :browser_user_agent_delete_after, precision: 6
      t.string :browser_user_agent_retain_until_rule
      t.datetime :browser_user_agent_deleted_at, precision: 6
      t.string :browser_user_agent_unavailable_reason

      t.string :ip_geolocation_country_code
      t.string :ip_geolocation_country_name
      t.string :ip_geolocation_region_name
      t.string :ip_geolocation_region_code
      t.string :ip_geolocation_city_name
      t.string :ip_geolocation_postal_code

      # Coordinates are strings, not decimals, for two reasons that point the
      # same way. A receipt serializes them as strings anyway, so storing the
      # decimal and formatting it back would introduce a rounding step between
      # what the provider said and what the evidence shows. And a string column
      # can carry ciphertext, which is what lets `encrypt_recorded_ip_geolocation`
      # actually apply to the most identifying field in this table rather than
      # being a setting that quietly does nothing.
      t.string :ip_geolocation_latitude
      t.string :ip_geolocation_longitude

      t.string :ip_geolocation_timezone
      t.string :ip_geolocation_continent_code
      t.string :ip_geolocation_metro_code

      t.string :ip_geolocation_provider_name
      t.string :ip_geolocation_provider_source
      t.string :ip_geolocation_database_version
      t.string :ip_geolocation_database_sha256
      t.integer :ip_geolocation_accuracy_radius_in_kilometers
      t.integer :ip_geolocation_accuracy_radius_confidence_percentage
      t.boolean :ip_geolocation_was_estimated, null: false, default: true
      t.boolean :ip_geolocation_source_was_verified_by_host, null: false, default: false
      t.datetime :ip_geolocation_resolved_at, precision: 6
      t.string :ip_geolocation_unavailable_reason
      t.datetime :ip_geolocation_recorded_at, precision: 6
      t.datetime :ip_geolocation_delete_after, precision: 6
      t.string :ip_geolocation_retain_until_rule
      t.datetime :ip_geolocation_deleted_at, precision: 6

      t.datetime :created_at, precision: 6, null: false
    end

    add_index :clickwrap_request_evidence, :event_id, unique: true,
              name: "index_clickwrap_request_evidence_on_event"
    add_index :clickwrap_request_evidence, :ip_address_delete_after,
              name: "index_clickwrap_request_evidence_on_ip_address_delete_after"
    add_index :clickwrap_request_evidence, :browser_user_agent_delete_after,
              name: "index_clickwrap_request_evidence_on_user_agent_delete_after"
    add_index :clickwrap_request_evidence, :ip_geolocation_delete_after,
              name: "index_clickwrap_request_evidence_on_geolocation_delete_after"


    add_clickwrap_foreign_key :clickwrap_events, :clickwrap_request_evidence,
                    column: :request_evidence_id, name: "fk_clickwrap_events_request_evidence"
    add_clickwrap_foreign_key :clickwrap_request_evidence, :clickwrap_events,
                    column: :event_id, name: "fk_clickwrap_request_evidence_event"
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