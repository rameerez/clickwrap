# frozen_string_literal: true

require "test_helper"

# The FinePrint importer, against real FinePrint-shaped tables.
#
# This class runs WITHOUT transactional fixtures. It has to: the test creates
# and drops the `fine_print_*` tables, and on MySQL a DDL statement implicitly
# commits the surrounding transaction, which destroys the savepoint the test
# harness is relying on. Every other suite in this repository keeps its
# transaction; this one cleans up after itself instead.
class FinePrintImportTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @user = create_user
  end

  teardown do
    connection = ActiveRecord::Base.connection
    connection.drop_table(:fine_print_signatures, if_exists: true)
    connection.drop_table(:fine_print_contracts, if_exists: true)

    Clickwrap::EventStatement.delete_all
    Clickwrap::EventDocument.delete_all
    Clickwrap::StatementState.delete_all
    Clickwrap::Event.delete_all
    User.delete_all
  end

  test "the importer says so plainly when FinePrint's tables are not there" do
    report = Clickwrap::Import::FinePrint.plan(
      policy_key: :signup, find_actor_with: ->(_type, id) { User.find(id) }
    )

    assert_not report.possible?
    assert_match(/fine_print/i, report.message)
    assert_equal 0, Clickwrap::Event.count
  end

  test "a plan reads FinePrint's tables and writes nothing" do
    create_fine_print_tables_with_one_signature

    plan = Clickwrap::Import::FinePrint.plan(
      policy_key: :signup, find_actor_with: ->(_type, id) { User.find(id) }
    )

    assert plan.possible?
    assert_equal 1, plan.signatures
    assert_equal 0, Clickwrap::Event.count

    # The plan says out loud which facts FinePrint never recorded, before
    # anyone commits to importing them as if it had.
    assert_includes plan.message, "unknown"
  end

  test "importing preserves what FinePrint knew and marks what it never recorded" do
    create_fine_print_tables_with_one_signature

    report = Clickwrap::Import::FinePrint.import!(
      policy_key: :signup, find_actor_with: ->(_type, id) { User.find(id) }
    )

    assert_equal 1, report.imported.length
    event = report.imported.first.event

    assert_equal "imported_legacy", event.event_type
    assert_equal 2019, event.occurred_at.year
    assert_operator event.recorded_at_by_server, :>, event.occurred_at

    # The gap between when it happened and when we wrote it down stays visible.
    # FinePrint recorded a signature; it did not record what was on screen, so
    # nothing here pretends otherwise.
    assert_nil event.presentation_manifest_digest
    assert_equal "fine_print", event.provider_verification["source"]
    assert_includes event.provider_verification["unknown"], "ip_address"
    assert_includes event.provider_verification["unknown"], "presentation_manifest"
  end

  test "re-running an import is a no-op rather than a duplicate" do
    create_fine_print_tables_with_one_signature
    options = { policy_key: :signup, find_actor_with: ->(_type, id) { User.find(id) } }

    Clickwrap::Import::FinePrint.import!(**options)
    rerun = Clickwrap::Import::FinePrint.import!(**options)

    assert_equal 1, rerun.already_imported.length
    assert_equal 1, Clickwrap::Event.for_policy("signup").count
  end

  test "an imported signature never satisfies a human-action predicate by accident" do
    create_fine_print_tables_with_one_signature
    Clickwrap::Import::FinePrint.import!(
      policy_key: :signup, find_actor_with: ->(_type, id) { User.find(id) }
    )

    # An import records that something happened elsewhere, once. Whether it
    # counts as current evidence is the host's decision, made by looking at the
    # event, not something the importer decides by writing a convincing row.
    event = Clickwrap::Event.for_policy("signup").last
    assert_equal "imported_legacy", event.event_type
    assert_not Clickwrap::Vocabulary.human_action_event_type?(event.event_type)
  end

  private

  def create_fine_print_tables_with_one_signature
    connection = ActiveRecord::Base.connection

    connection.create_table(:fine_print_contracts, force: true) do |t|
      t.string :name
      t.string :version
      t.string :title
      t.text :content
      t.timestamps
    end

    connection.create_table(:fine_print_signatures, force: true) do |t|
      t.integer :contract_id
      t.string :user_type
      t.integer :user_id
      t.timestamps
    end

    contract_id = connection.insert(
      "INSERT INTO fine_print_contracts (name, version, title, created_at, updated_at) " \
      "VALUES ('terms', '3', 'Terms of Use', '2019-01-01', '2019-01-01')"
    )

    connection.insert(
      "INSERT INTO fine_print_signatures (contract_id, user_type, user_id, created_at, updated_at) " \
      "VALUES (#{contract_id}, 'User', #{@user.id}, '2019-02-03 10:00:00', '2019-02-03 10:00:00')"
    )
  end
end
