# frozen_string_literal: true

require "test_helper"

# The cheapest, highest-value assertions: the engine booted inside a real host,
# taught Zeitwerk about its models, wired the macro and the form builder, loaded
# the host's declarations, and created its tables — all with no app-code edits
# beyond `has_clickwraps` and one config file.
class BootTest < ActiveSupport::TestCase
  test "gem has a version" do
    assert_match(/\A\d+\.\d+\.\d+\z/, Clickwrap::VERSION)
  end

  test "the engine is mounted in the dummy host" do
    assert_includes Rails.application.routes.routes.map { |route| route.app.app.to_s },
                    "Clickwrap::Engine"
  end

  test "has_clickwraps gave the actor model its proxy and associations" do
    assert_includes User.ancestors, Clickwrap::HasClickwraps

    user = create_user
    assert_respond_to user, :clickwraps
    assert_respond_to user, :clickwrap_events
    assert_instance_of Clickwrap::ActorProxy, user.clickwraps
  end

  test "the form builder learned form.clickwrap" do
    assert_includes ActionView::Helpers::FormBuilder.ancestors, Clickwrap::FormBuilderExtensions
  end

  test "every clickwrap model is autoloadable and points at its prefixed table" do
    {
      Clickwrap::Document => "clickwrap_documents",
      Clickwrap::DocumentVersion => "clickwrap_document_versions",
      Clickwrap::PolicyRevision => "clickwrap_policy_revisions",
      Clickwrap::Presentation => "clickwrap_presentations",
      Clickwrap::Event => "clickwrap_events",
      Clickwrap::EventStatement => "clickwrap_event_statements",
      Clickwrap::EventDocument => "clickwrap_event_documents",
      Clickwrap::StatementState => "clickwrap_statement_states",
      Clickwrap::StatementIdentityLock => "clickwrap_statement_identity_locks",
      Clickwrap::RequestEvidence => "clickwrap_request_evidence",
      Clickwrap::LegalHold => "clickwrap_legal_holds",
      Clickwrap::ChainHead => "clickwrap_chain_heads",
      Clickwrap::ExternalAction => "clickwrap_external_actions",
      Clickwrap::DispositionPlan => "clickwrap_disposition_plans",
      Clickwrap::ReceiptAccess => "clickwrap_receipt_accesses",
      Clickwrap::IntegrityAttestation => "clickwrap_integrity_attestations"
    }.each do |model, table|
      assert_equal table, model.table_name
      assert model.table_exists?, "expected #{table} to exist"
    end
  end

  test "the gem's models do not inherit from the host's ApplicationRecord" do
    # Evidence tables must behave identically in every host. A default scope or
    # a callback bolted onto the app's base class could change what gets
    # recorded, or hide rows from an export that is supposed to be complete.
    assert_not_includes Clickwrap::Event.ancestors, ::ApplicationRecord
    assert_includes Clickwrap::Event.ancestors, Clickwrap::ApplicationRecord
  end

  test "the host's declarations compiled at boot" do
    assert_includes Clickwrap.policies.keys, "signup"
    assert_includes Clickwrap.policies.keys, "withdrawal_authorization"
    assert_includes Clickwrap.retention_classes.keys, "ordinary_agreement_evidence"
    assert(Clickwrap.documents.values.any? { |definition| definition.key == "terms" })
  end

  test "the events table has no updated_at column" do
    # A mutable timestamp on an append-only record is an invitation to treat it
    # as mutable. There is deliberately no such column.
    assert_not_includes Clickwrap::Event.column_names, "updated_at"
  end

  test "the database refuses orphaned non-polymorphic evidence" do
    expected = {
      clickwrap_events: [
        %w[clickwrap_events root_event_id],
        %w[clickwrap_events predecessor_event_id],
        %w[clickwrap_events core_event_disposition_event_id],
        %w[clickwrap_request_evidence request_evidence_id]
      ],
      clickwrap_event_statements: [%w[clickwrap_events event_id]],
      clickwrap_event_documents: [%w[clickwrap_events event_id]],
      clickwrap_statement_states: [
        %w[clickwrap_events current_event_id],
        %w[clickwrap_events root_event_id]
      ],
      clickwrap_request_evidence: [%w[clickwrap_events event_id]],
      clickwrap_legal_holds: [%w[clickwrap_events event_id]],
      clickwrap_chain_heads: [%w[clickwrap_events last_event_id]],
      clickwrap_external_actions: [%w[clickwrap_events event_id]],
      clickwrap_receipt_accesses: [%w[clickwrap_events event_id]],
      clickwrap_integrity_attestations: [%w[clickwrap_events event_id]]
    }

    expected.each do |table, required_links|
      actual = ActiveRecord::Base.connection.foreign_keys(table).map do |foreign_key|
        [foreign_key.to_table.to_s, foreign_key.options.fetch(:column).to_s]
      end

      required_links.each do |link|
        assert_includes actual, link, "expected #{table}.#{link.last} to reference #{link.first}"
      end
    end
  end

  test "one event cannot acquire several outboxes or share a request-evidence annex" do
    connection = ActiveRecord::Base.connection
    external_action_event = connection.indexes(:clickwrap_external_actions).find do |index|
      index.columns == ["event_id"]
    end
    event_request_evidence = connection.indexes(:clickwrap_events).find do |index|
      index.columns == ["request_evidence_id"]
    end

    assert_predicate external_action_event, :unique
    assert_predicate event_request_evidence, :unique
  end

  test "every persisted datetime keeps microsecond precision" do
    connection = ActiveRecord::Base.connection
    clickwrap_tables = connection.tables.grep(/\Aclickwrap_/)

    clickwrap_tables.each do |table|
      connection.columns(table).select { |column| %i[datetime timestamp].include?(column.type) }.each do |column|
        assert_equal 6, column.precision,
                     "expected #{table}.#{column.name} to preserve six fractional digits"
      end
    end
  end

  test "host polymorphic identifiers are stored as strings" do
    connection = ActiveRecord::Base.connection
    expected = {
      clickwrap_presentations: %w[actor_id represented_party_id subject_id],
      clickwrap_events: %w[actor_id represented_party_id subject_id],
      clickwrap_statement_states: %w[actor_id subject_id]
    }

    expected.each do |table, columns|
      by_name = connection.columns(table).index_by(&:name)
      columns.each do |column|
        assert_equal :string, by_name.fetch(column).type,
                     "expected #{table}.#{column} to accept integer, UUID, or string host keys"
      end
    end
  end

  test "query-backed lookup indexes are present" do
    connection = ActiveRecord::Base.connection
    expected = {
      clickwrap_presentations: [%w[expires_at], %w[actor_reference]],
      clickwrap_events: [%w[presentation_id], %w[request_evidence_id], %w[retention_class_key], %w[subject_key]],
      clickwrap_statement_states: [%w[root_event_id]],
      clickwrap_legal_holds: [%w[policy_key released_at]],
      clickwrap_external_actions: [%w[event_id]]
    }

    expected.each do |table, column_sets|
      actual = connection.indexes(table).map(&:columns)
      column_sets.each do |columns|
        assert_includes actual, columns, "expected an index on #{table}(#{columns.join(", ")})"
      end
    end
  end

  test "the database rejects contradictory requirement flags and unknown lifecycle values" do
    connection = ActiveRecord::Base.connection
    expected = {
      clickwrap_presentations: %w[chk_clickwrap_presentations_state chk_clickwrap_presentations_channel],
      clickwrap_events: %w[chk_clickwrap_events_event_type chk_clickwrap_events_channel
                           chk_clickwrap_events_attribution],
      clickwrap_event_statements: %w[chk_clickwrap_statements_kind chk_clickwrap_statements_action
                                     chk_clickwrap_statements_requirement],
      clickwrap_statement_states: %w[chk_clickwrap_states_state],
      clickwrap_legal_holds: %w[chk_clickwrap_holds_scope],
      clickwrap_external_actions: %w[chk_clickwrap_external_actions_state],
      clickwrap_disposition_plans: %w[chk_clickwrap_disposition_plans_kind chk_clickwrap_disposition_plans_state],
      clickwrap_integrity_attestations: %w[chk_clickwrap_attestations_kind chk_clickwrap_attestations_state]
    }

    expected.each do |table, names|
      actual = connection.check_constraints(table).map(&:name)
      names.each { |name| assert_includes actual, name }
    end
  end

  test "every public constant is autoloadable from its own file" do
    # Zeitwerk maps one constant to one file. Two classes sharing a file resolve
    # under eager loading and then raise NameError in an ordinary development
    # app, which is how `Clickwrap.system_actor` was broken everywhere except
    # this suite until a real host app tried it.
    assert_equal "system/seed", Clickwrap.system_actor("seed").clickwrap_actor_reference
    assert_equal "anonymous/checkout_1", Clickwrap.anonymous_actor("checkout_1").clickwrap_actor_reference

    { Clickwrap::AnonymousActor => "lib/clickwrap/anonymous_actor.rb",
      Clickwrap::SystemActor => "lib/clickwrap/system_actor.rb" }.each do |constant, path|
      expected = Clickwrap::Engine.root.join(path).to_s
      assert_equal expected, Object.const_source_location(constant.name).first
    end
  end

  test "the six kinds and their actions are frozen vocabularies" do
    assert_equal 6, Clickwrap::Vocabulary::KINDS.length
    assert Clickwrap::Vocabulary::KINDS.frozen?
    assert Clickwrap::Vocabulary::ACTIONS_FOR_KIND.frozen?
  end
end
