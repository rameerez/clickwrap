# frozen_string_literal: true

require "test_helper"
require "erb"
require "generators/clickwrap/hardening_generator"

class DatabaseHardeningTest < ActiveSupport::TestCase
  TEMPLATE = File.expand_path(
    "../lib/generators/clickwrap/templates/clickwrap_hardening.rb.erb",
    __dir__
  )

  test "PostgreSQL hardening permits every named lifecycle and rejects callback bypasses" do
    skip "PostgreSQL-only trigger contract" unless postgresql?

    with_database_hardening do
      user = create_user
      receipt = submit_clickwrap(
        :signup,
        actor: user,
        answers: { terms: "1", privacy_notice: "1" }
      )
      event = receipt.event.reload

      assert_database_rejects { event.update_column(:reason, "rewritten through update_column") }
      assert_database_rejects { Clickwrap::Event.where(id: event.id).update_all(reason: "bulk rewrite") }
      assert_database_rejects { event.delete }
      assert_database_rejects { Clickwrap::Event.where(id: event.id).delete_all }
      assert_database_rejects do
        Clickwrap::EventStatement.where(event_id: event.id).update_all(answer: "forged")
      end
      assert_database_rejects do
        Clickwrap::EventDocument.where(event_id: event.id).delete_all
      end

      receipt.place_on_legal_hold!(
        because: "Dispute 2026-184",
        placed_by: create_security_operator,
        review_at: 30.days.from_now
      )
      assert event.reload.on_legal_hold?

      receipt.release_legal_hold!(
        because: "Dispute resolved",
        released_by: create_security_operator
      )
      assert_not event.reload.on_legal_hold?

      disposition = Clickwrap::Retention::Disposition.dispose_core_event!(
        event,
        because: "The reviewed core-evidence schedule ended."
      )
      assert disposition.digest_verified?
      assert event.reload.documented_core_disposition?
      assert_empty Clickwrap::EventStatement.where(event_id: event.id)
      assert_empty Clickwrap::EventDocument.where(event_id: event.id)

      deletable_user = create_user
      deletable_receipt = submit_clickwrap(
        :signup,
        actor: deletable_user,
        answers: { terms: "1", privacy_notice: "1" }
      )
      stable_reference = deletable_receipt.event.actor_reference

      deletable_user.destroy!

      orphaned_event = deletable_receipt.event.reload
      assert_nil orphaned_event.actor_id
      assert_nil orphaned_event.actor_type
      assert_equal stable_reference, orphaned_event.actor_reference
      assert orphaned_event.digest_verified?
    end
  end

  private

  def postgresql?
    ActiveRecord::Base.connection.adapter_name.downcase.include?("postgresql")
  end

  def with_database_hardening
    source = ERB.new(File.read(TEMPLATE)).result_with_hash(
      migration_version: "[7.1]",
      event_write_sets_for_migration:
        Clickwrap::Generators::HardeningGenerator.render_event_write_sets
    )
    namespace = Module.new
    namespace.module_eval(source, TEMPLATE, 1)
    migration = namespace.const_get(:ClickwrapDatabaseHardening).new
    migration.migrate(:up)
    yield
  ensure
    migration&.migrate(:down) if postgresql?
  end

  def assert_database_rejects(&block)
    assert_raises(ActiveRecord::StatementInvalid) do
      ActiveRecord::Base.transaction(requires_new: true, &block)
    end
  end
end
