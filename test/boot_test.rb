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
      Clickwrap::RequestEvidence => "clickwrap_request_evidence",
      Clickwrap::LegalHold => "clickwrap_legal_holds",
      Clickwrap::ChainHead => "clickwrap_chain_heads",
      Clickwrap::ExternalAction => "clickwrap_external_actions",
      Clickwrap::DispositionPlan => "clickwrap_disposition_plans",
      Clickwrap::ReceiptAccess => "clickwrap_receipt_accesses"
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
