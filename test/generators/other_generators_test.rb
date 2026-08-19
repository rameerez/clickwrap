# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/clickwrap/policy_generator"
require "generators/clickwrap/document_generator"
require "generators/clickwrap/views_generator"
require "generators/clickwrap/hardening_generator"
require "generators/clickwrap/upgrade_generator"
require "tmpdir"

# The four generators a host reaches for after installing, plus the upgrade one
# it will reach for later. Each is tested for the thing that would hurt if it
# regressed rather than for the fact that it wrote a file.
class PolicyGeneratorTest < Rails::Generators::TestCase
  tests Clickwrap::Generators::PolicyGenerator
  destination Dir.mktmpdir("clickwrap-generator-policy-")
  setup :prepare_destination

  teardown do
    FileUtils.rm_rf(destination_root)
  end

  test "generating a policy writes one explicit statement that compiles immediately" do
    run_generator [
      "generated_declaration", "declare",
      "--statement-text=I declare that the supplied information is accurate."
    ]

    assert_file "config/clickwrap/generated_declaration.rb" do |policy|
      assert_match(/Clickwrap\.policy :generated_declaration do/, policy)
      assert_match(/^\s*declare :generated_declaration,/, policy)
      assert_match(/document: nil/, policy)
      assert_match(/statement: "I declare that the supplied information is accurate\."/, policy)
      assert_match(/retain_with :ordinary_agreement_evidence/, policy)
    end

    load File.join(destination_root, "config/clickwrap/generated_declaration.rb")
    generated = Clickwrap.policy!(:generated_declaration)
    assert_equal ["generated_declaration"], generated.statements.map(&:key)
    assert_equal ["declaration"], generated.statements.map(&:kind)

    # A policy is executable meaning, so it ships with a test the same way a
    # model does.
    assert_file "test/clickwrap/generated_declaration_policy_test.rb" do |policy_test|
      assert_match(/class GeneratedDeclarationPolicyTest < ActiveSupport::TestCase/, policy_test)
      assert_match(/include Clickwrap::TestHelpers/, policy_test)
      assert_match(/it refuses an incomplete submission/, policy_test)
      assert_match(/a failed evidence write rolls the protected action back/, policy_test)
    end
  end

  test "the generator refuses to guess the verb, statement copy, or consent withdrawal path" do
    missing_verb = capture(:stderr) do
      run_generator ["missing_verb", "--statement-text=I declare this."]
    end
    assert_match(/No value provided for required arguments? ['`]verb['`]/, missing_verb)
    assert_no_file "config/clickwrap/missing_verb.rb"

    missing_copy = capture(:stderr) { run_generator %w[missing_copy declare] }
    assert_match(/required options? ['`].*statement[_-]text/i, missing_copy)
    assert_no_file "config/clickwrap/missing_copy.rb"

    missing_withdrawal = capture(:stderr) do
      run_generator ["marketing", "consent_to", "--statement-text=I want product updates."]
    end
    assert_match(/needs --withdrawal-path/, missing_withdrawal)
    assert_no_file "config/clickwrap/marketing.rb"
  end

  test "a dashed or namespaced policy name becomes one underscored policy key" do
    run_generator [
      "Billing/manual-transfer", "authorize",
      "--statement-text=I authorize this manual transfer."
    ]

    assert_file "config/clickwrap/billing_manual_transfer.rb", /Clickwrap\.policy :billing_manual_transfer do/
    assert_file "test/clickwrap/billing_manual_transfer_policy_test.rb",
                /class BillingManualTransferPolicyTest/
  end
end

class DocumentGeneratorTest < Rails::Generators::TestCase
  tests Clickwrap::Generators::DocumentGenerator
  destination Dir.mktmpdir("clickwrap-generator-document-")
  setup :prepare_destination

  teardown do
    FileUtils.rm_rf(destination_root)
  end

  test "generating a document declares it version-less and the file names its own version" do
    run_generator %w[terms]

    assert_file "config/clickwrap.rb" do |declarations|
      assert_match(/Clickwrap\.document :terms,/, declarations)
      refute_match(/version:/, declarations,
                   "the file's front matter names the version — a second copy of the label " \
                   "in the declaration is exactly the pair that drifts")
      assert_match(%r{from: Rails\.root\.join\("app/content/legal/terms\.md"\)}, declarations)
    end

    # Declaring is not publishing, and the placeholder says out loud that it is
    # not legal text — a gem that shipped plausible-looking Terms would be
    # inviting someone to publish words nobody read.
    assert_file "app/content/legal/terms.md" do |content|
      assert_match(/PLACEHOLDER/, content)
      assert_match(/clickwrap:publish/, content)
      assert_equal Date.today.iso8601, Clickwrap::FrontMatter.version_label_in(content),
                   "the placeholder must resolve the version label Clickwrap reads at boot"
    end
  end

  test "an explicit --document-version lands in the file's front matter, not the declaration" do
    run_generator %w[terms --document-version=v2.1]

    assert_file "app/content/legal/terms.md" do |content|
      assert_equal "v2.1", Clickwrap::FrontMatter.version_label_in(content),
                   "clickwrap_version: must outrank last_updated: so a hand-chosen label " \
                   "and a human-facing date coexist"
      assert_match(/^last_updated: #{Date.today.iso8601}$/, content)
    end

    assert_file "config/clickwrap.rb" do |declarations|
      refute_match(/version:/, declarations)
    end
  end

  test "a second run for the same document declares nothing and explains the one-file flow" do
    run_generator %w[terms]
    output = run_generator %w[terms]

    assert_file "config/clickwrap.rb" do |declarations|
      # One declaration per key: a "new version" is a front-matter bump in the
      # file, and a second version-less declaration of the same key would be
      # refused at boot as a duplicate anyway.
      assert_equal 1, declarations.scan("Clickwrap.document :terms,").length
    end
    assert_match(/front-matter bump/, output)
  end

  test "a locale-specific version gets its own content file and its own declaration" do
    run_generator %w[terms --locale=es]

    assert_file "config/clickwrap.rb", /locale: :es,/
    assert_file "app/content/legal/terms.es.md" do |content|
      assert_equal Date.today.iso8601, Clickwrap::FrontMatter.version_label_in(content)
    end
  end
end

class ViewsGeneratorTest < Rails::Generators::TestCase
  tests Clickwrap::Generators::ViewsGenerator
  destination Dir.mktmpdir("clickwrap-generator-views-")
  setup :prepare_destination

  teardown do
    FileUtils.rm_rf(destination_root)
  end

  test "ejecting the views copies every overridable template into the host" do
    run_generator

    # The host's app/views sits ahead of the engine's in the lookup chain, so a
    # copy at this exact path shadows the gem's default with no configuration.
    assert_file "app/views/clickwrap/shared/_fields.html.erb"
    assert_file "app/views/clickwrap/shared/_statement.html.erb"
    assert_file "app/views/clickwrap/shared/_error_summary.html.erb"
    assert_file "app/views/clickwrap/captures/show.html.erb"
    assert_file "app/views/clickwrap/receipts/index.html.erb"
    assert_file "app/views/clickwrap/receipts/show.html.erb"
    assert_file "app/views/clickwrap/withdrawals/new.html.erb"
  end

  test "ejecting a single group copies that group and leaves the rest in the gem" do
    run_generator %w[--views shared]

    assert_file "app/views/clickwrap/shared/_fields.html.erb"
    assert_no_file "app/views/clickwrap/captures/show.html.erb"
    assert_no_file "app/views/clickwrap/withdrawals/new.html.erb"
  end

  test "asking for a group that does not exist says which groups do" do
    output = run_generator %w[--views nonexistent]

    assert_match(/No `nonexistent` views ship with this release/, output)
    assert_match(/Available: captures, receipts, shared, withdrawals/, output)
    assert_no_file "app/views/clickwrap/shared/_fields.html.erb"
  end
end

class HardeningGeneratorTest < Rails::Generators::TestCase
  tests Clickwrap::Generators::HardeningGenerator
  destination Dir.mktmpdir("clickwrap-generator-hardening-")
  setup :prepare_destination

  teardown do
    FileUtils.rm_rf(destination_root)
  end

  # The adapter is stubbed rather than inherited from whichever database this
  # suite happens to be running against, because the whole point of these tests
  # is what the generator says on each adapter — and CI runs three of them.
  def stub_adapter!(name)
    Clickwrap::Generators::HardeningGenerator.any_instance.stubs(:database_adapter).returns(name)
  end

  test "asking for database hardening creates a reversible migration that names what it protects" do
    stub_adapter! "postgresql"

    run_generator %w[--database]

    assert_migration "db/migrate/clickwrap_database_hardening.rb" do |migration|
      assert_match(/def up/, migration)
      # Reversible in the literal sense: `db:rollback` drops what it created and
      # touches no data. A one-way hardening migration would be a trap.
      assert_match(/def down/, migration)
      assert_match(/DROP TRIGGER IF EXISTS clickwrap_events_guard_update ON clickwrap_events;/, migration)
      assert_match(/EVENT_WRITE_SETS = \{/, migration)
      assert_match(/"pointer_nullification" => %w\[/, migration)
      assert_match(/"disposition" => %w\[/, migration)
      namespace = Module.new
      namespace.module_eval(migration, "generated_clickwrap_database_hardening.rb", 1)
      generated_class = namespace.const_get(:ClickwrapDatabaseHardening)
      assert_equal Clickwrap::Event::DATABASE_HARDENING_WRITE_SETS,
                   generated_class::EVENT_WRITE_SETS
      assert_match(/Evidence children may be deleted only by a documented core disposition/, migration)

      # The optional personal annex stays deletable on its retention schedule —
      # that is the entire reason it is a separate table.
      assert_match(/Optional personal request-evidence annex values remain separately disposable/, migration)
      assert_match(/clickwrap_request_evidence/, migration)

      # The claim is bounded and stated as such, in the file itself.
      assert_match(/does not make evidence impossible to alter/i, migration)
    end
  end

  test "on SQLite the generator says the migration will do nothing, and why that is honest" do
    stub_adapter! "sqlite3"

    output = run_generator %w[--database]

    assert_match(/SQLite detected/, output)
    assert_match(/will run and do nothing/, output)
    # No users, no roles, no privileges: anything that can write the file can
    # drop the trigger. Saying so beats installing theatre.
    assert_match(/can drop a trigger/, output)
    assert_match(/What still holds on SQLite/, output)
    assert_match(/the models refuse update and destroy/, output)
  end

  test "the PostGIS adapter is treated as PostgreSQL by both generator and migration" do
    stub_adapter! "postgis"

    output = run_generator %w[--database]

    assert_match(/PostgreSQL detected/, output)
    assert_migration "db/migrate/clickwrap_database_hardening.rb" do |migration|
      assert_match(%r{match\?\(/postgres\|postgis/\)}, migration)
    end
  end

  test "on MySQL the generator says which control does work there instead of pretending" do
    stub_adapter! "mysql2"

    output = run_generator %w[--database]

    assert_match(/MySQL detected/, output)
    assert_match(/will run and do nothing/, output)
    assert_match(/privilege separation/, output)
    assert_match(/a protection that\s+the protected account can remove is a comment, not a control/, output)
  end

  test "an unrecognized adapter is reported as untested rather than quietly assumed to work" do
    stub_adapter! "informix"

    output = run_generator %w[--database]

    assert_match(/informix is outside the tested set/, output)
    assert_match(/runs and does nothing rather than executing DDL nobody has tested/, output)
  end

  test "database hardening is never applied as a side effect of installing the gem" do
    stderr = capture(:stderr) { run_generator }

    # It changes what the database will accept in every environment the
    # migration runs in, so it has to be asked for by name.
    assert_match(/Nothing was generated, on purpose/, stderr)
    assert_match(/rails generate clickwrap:hardening --database/, stderr)
    assert_no_migration "db/migrate/clickwrap_database_hardening.rb"
  end
end

class UpgradeGeneratorTest < Rails::Generators::TestCase
  tests Clickwrap::Generators::UpgradeGenerator
  destination Dir.mktmpdir("clickwrap-generator-upgrade-")
  setup :prepare_destination

  teardown do
    FileUtils.rm_rf(destination_root)
  end

  test "at 0.1.0 the upgrade generator says there is nothing to upgrade from and creates nothing" do
    output = run_generator

    assert_match(/has no upgrade migrations/, output)
    assert_match(/0\.1\.0 is the first release/, output)
    assert_match(%r{bin/rails generate clickwrap:install}, output)

    # Writing an empty migration to look busy would leave a released migration
    # file in someone's application forever, for nothing.
    assert_empty Dir.glob(File.join(destination_root, "**/*"))
  end
end
