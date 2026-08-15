# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/clickwrap/install_generator"

# `rails generate clickwrap:install` is the first thing anyone runs, and almost
# everything it writes is a decision with consequences years later: the schema
# evidence is stored under, and an initializer whose defaults decide what
# personal data this application starts collecting about people.
#
# Every run below passes `--skip-questions`, a recipe, or an explicit field flag,
# because the interactive path reads from $stdin and a test suite has no keyboard.
class InstallGeneratorTest < Rails::Generators::TestCase
  tests Clickwrap::Generators::InstallGenerator
  # The gem root's tmp/, which is already gitignored — a generator scratch
  # directory that shows up in `git status` is a generator scratch directory
  # someone eventually commits.
  destination File.expand_path("../../tmp/generators/install", __dir__)
  setup :prepare_destination

  teardown do
    FileUtils.rm_rf(destination_root)
  end

  # Every request-evidence setting the initializer is supposed to write, in the
  # order the template writes them. Named here rather than derived from the
  # template so a setting silently disappearing from the template fails.
  RECORD_SETTINGS = [
    "record_ip_address_by_default",
    "record_browser_user_agent_by_default",
    *Clickwrap::Vocabulary::IP_GEOLOCATION_DATA_FIELDS.map { |field| "record_ip_geolocation_#{field}_by_default" }
  ].freeze

  # Words that would turn a scaffolding convenience into a runtime mode switch.
  # None of them may appear as a setting in a file this generator writes.
  FORBIDDEN_MODE_SETTINGS = %w[
    gdpr_compliant_mode maximum_evidence full_evidence legal_proof record_network_context
  ].freeze

  test "installing writes the migration, the initializer, the policy file, and the legal placeholders" do
    run_generator %w[--skip-questions]

    assert_migration "db/migrate/create_clickwrap_tables.rb", /create_table :clickwrap_events/
    assert_file "config/initializers/clickwrap.rb", /Clickwrap\.configure do \|config\|/
    assert_file "config/clickwrap.rb", /Clickwrap\.policy :signup do/
    assert_file "config/clickwrap.rb", /Clickwrap\.retention :ordinary_agreement_evidence do/

    # Placeholders, never legal text. Both say so in their own first lines.
    assert_file "app/content/legal/terms.md", /PLACEHOLDER/
    assert_file "app/content/legal/privacy.md", /PLACEHOLDER/
  end

  test "installing twice does not write the migration a second time" do
    run_generator %w[--skip-questions]
    run_generator %w[--skip-questions]

    # Two CreateClickwrapTables migrations in one application is not a cosmetic
    # duplicate: the second one fails at `db:migrate` on a table that exists.
    assert_equal 1, Dir.glob(File.join(destination_root, "db/migrate/*_create_clickwrap_tables.rb")).length
  end

  test "the migration adapts its key types, JSON columns, and long-text columns to the host database" do
    run_generator %w[--skip-questions]

    assert_migration "db/migrate/create_clickwrap_tables.rb" do |migration|
      # uuid-vs-bigint follows the host's own generator setting, so clickwrap
      # tables can be embedded in a uuid app's polymorphic associations.
      assert_match(/primary_key_type, foreign_key_type = primary_and_foreign_key_types/, migration)
      assert_match(/config\.options\[config\.orm\]\[:primary_key_type\]/, migration)

      # Column types resolve at MIGRATION RUN time, so one file works across the
      # dev/prod database split as well as across the CI matrix.
      assert_match(/return :jsonb if connection\.adapter_name\.downcase\.include\?\("postgresql"\)/, migration)
      assert_match(/def json_column_type/, migration)

      # MySQL 8 refuses a default on a JSON column, so the default itself is a
      # branch rather than a literal.
      assert_match(/def json_column_default/, migration)
      assert_match(/def json_array_default/, migration)
      assert_match(/return nil if connection\.adapter_name\.downcase\.include\?\("mysql"\)/, migration)

      # A silently truncated agreement is the worst failure this gem has, so
      # document bodies get MEDIUMTEXT on MySQL and ordinary TEXT elsewhere.
      assert_match(/return :mediumtext if connection\.adapter_name\.downcase\.include\?\("mysql"\)/, migration)
      assert_match(/t\.send\(text_column_type, :content\)/, migration)
    end
  end

  test "the initializer writes every request-evidence setting, and every one of them is off" do
    run_generator %w[--skip-questions]

    assert_file "config/initializers/clickwrap.rb" do |initializer|
      RECORD_SETTINGS.each do |setting|
        # Off is the safe default and it has to be WRITTEN rather than implied:
        # a setting that is absent from the file is a setting nobody reviews.
        assert_match(/^\s*config\.#{setting} = false$/, initializer,
                     "Expected config.#{setting} to be written and set to false")
      end

      # Nothing is enabled, so there is nothing to justify, delete, or resolve.
      assert_match(/config\.reason_for_recording_ip_addresses_by_default = nil/, initializer)
      assert_match(/config\.delete_recorded_ip_addresses_after = nil/, initializer)
      assert_match(/config\.ip_geolocation_resolver = nil/, initializer)
      assert_match(/config\.review_default_request_evidence_configuration_on = nil/, initializer)
    end
  end

  test "the evidence-rich recipe expands into individual settings and leaves no runtime switch behind" do
    run_generator %w[--request-evidence-recipe=evidence-rich]

    assert_file "config/initializers/clickwrap.rb" do |initializer|
      RECORD_SETTINGS.each do |setting|
        assert_match(/^\s*config\.#{setting} = true$/, initializer,
                     "Expected the evidence-rich recipe to write config.#{setting} = true")
      end

      # The recipe cannot supply a purpose, so it writes the one honest thing it
      # can: a placeholder that says a human still has to.
      %w[
        reason_for_recording_ip_addresses_by_default
        reason_for_recording_browser_user_agents_by_default
        reason_for_recording_ip_geolocation_by_default
      ].each do |reason|
        assert_match(/config\.#{reason} =\s*\n?\s*"TODO: replace with your reviewed purpose[^"]*"/, initializer,
                     "Expected config.#{reason} to be a TODO placeholder rather than an invented sentence")
      end

      # THE POINT OF THE FLAG: it is scaffolding. It expanded into the lines
      # above and then stopped existing. Nothing here may read as a mode.
      FORBIDDEN_MODE_SETTINGS.each do |name|
        refute_match(/^\s*config\.[\w.]*#{name}/, initializer,
                     "#{name} must never exist as a runtime setting — a flag cannot make a legal determination")
      end
      refute_match(/^\s*config\.[\w.]*recipe/, initializer,
                   "the recipe is generator-only and must not survive into the configuration")
    end
  end

  test "asking for IP addresses on the command line turns on that one setting and nothing else" do
    run_generator %w[--record-ip-addresses-by-default]

    assert_file "config/initializers/clickwrap.rb" do |initializer|
      assert_match(/^\s*config\.record_ip_address_by_default = true$/, initializer)

      # Nothing rides along. A field that switches on as a side effect of another
      # field is exactly the failure this gem exists not to have.
      (RECORD_SETTINGS - ["record_ip_address_by_default"]).each do |setting|
        assert_match(/^\s*config\.#{setting} = false$/, initializer,
                     "Enabling IP addresses must not enable #{setting}")
      end

      assert_match(/config\.reason_for_recording_ip_addresses_by_default =\s*\n?\s*"TODO/, initializer)
      assert_match(/config\.delete_recorded_ip_addresses_after = 90\.days/, initializer)
      assert_match(/config\.reason_for_recording_browser_user_agents_by_default = nil/, initializer)
      assert_match(/config\.ip_geolocation_resolver = nil/, initializer)
    end
  end

  test "nothing the installer writes or prints claims what this gem cannot claim" do
    output = run_generator %w[--skip-questions]

    generated = Dir.glob(File.join(destination_root, "**/*")).select { |path| File.file?(path) }
    assert_operator generated.length, :>, 0, "the generator wrote nothing, so this proves nothing"

    ([output] + generated.map { |path| File.read(path) }).each do |body|
      Clickwrap::Vocabulary::PROHIBITED_CLAIM_PHRASES.each do |phrase|
        refute_includes body.downcase, phrase,
                        "Generated output claims #{phrase.inspect}, which no library can honestly claim"
      end
    end
  end

  # --- The drift test ---------------------------------------------------------
  #
  # The dummy app migrates a CONCRETE COPY of the ERB template on every CI
  # database leg (sqlite / postgres / mysql). These three tests fail the build the
  # moment the template and that copy disagree, so "the migration the dummy
  # proved" and "the migration users actually get" can never diverge silently —
  # which would mean the whole suite is green against a schema nobody ships.

  TEMPLATE_MIGRATION = File.expand_path(
    "../../lib/generators/clickwrap/templates/create_clickwrap_tables.rb.erb", __dir__
  )
  DUMMY_MIGRATION = File.expand_path(
    "../dummy/db/migrate/20260101000001_create_clickwrap_tables.rb", __dir__
  )

  test "the dummy's clickwrap migration declares the same columns as the template" do
    assert_equal column_names_in(TEMPLATE_MIGRATION), column_names_in(DUMMY_MIGRATION)
  end

  test "the dummy's clickwrap migration declares the same tables as the template" do
    assert_equal table_names_in(TEMPLATE_MIGRATION), table_names_in(DUMMY_MIGRATION)
  end

  test "the dummy's clickwrap migration declares the same indexes as the template" do
    # The unique indexes here are load-bearing behavior, not tuning: they are
    # what make a duplicate submit lose an INSERT race instead of producing two
    # live authorizations.
    assert_equal index_names_in(TEMPLATE_MIGRATION), index_names_in(DUMMY_MIGRATION)
  end

  private

  # Set semantics (uniq): a template carries BOTH branches of an ERB conditional,
  # of which exactly one survives generation.
  def column_names_in(path)
    source = File.read(path)
    plain = source.scan(
      /^\s*t\.(?:string|text|datetime|decimal|bigint|uuid|integer|json|jsonb|boolean|references) :(\w+)/
    )
    sent = source.scan(/^\s*t\.send\(\w+, :(\w+)/)
    (plain + sent).flatten.uniq
  end

  def table_names_in(path)
    File.read(path).scan(/create_table :(\w+)/).flatten.uniq
  end

  def index_names_in(path)
    File.read(path).scan(/name: "(index_\w+)"/).flatten.uniq
  end
end
