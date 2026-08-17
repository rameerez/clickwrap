# frozen_string_literal: true

require "test_helper"

# The cheapest, highest-value assertions: the engine booted inside a real host,
# taught Zeitwerk about its models, wired the macro and the form builder, loaded
# the host's declarations, and created its tables — all with no app-code edits
# beyond `has_clickwraps` and one config file.
class BootTest < ActiveSupport::TestCase
  test "the official Trackdown adapter is available in a host initializer without a private require" do
    assert defined?(Clickwrap::IpGeolocation::TrackdownResolver)
    assert_not defined?(::Trackdown), "naming the adapter must not load its optional dependency"
  end

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

  test "host views can render the canonical statement partial without loading an engine controller" do
    assert_includes ActionView::Base.ancestors, Clickwrap::ViewHelpers
    assert ActionView::Base.method_defined?(:clickwrap_document_link_html_options)
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

  # --- One constant, one file, for every file --------------------------------
  #
  # Zeitwerk maps one constant to one file. Two classes sharing a file resolve
  # under eager loading and then raise NameError in an ordinary development app,
  # which is how `Clickwrap.system_actor` was broken everywhere except this
  # suite until a real host app tried it.
  #
  # This used to check two constants while claiming to check every one. It now
  # walks the files themselves and asks, of each, the question Zeitwerk asks:
  # does this file define exactly the constant its path names?

  CLICKWRAP_LIB = Clickwrap::Engine.root.join("lib/clickwrap").to_s

  # Zeitwerk defines these from their paths. The models directories are
  # collapsed, so `models/event.rb` names `Clickwrap::Event` rather than
  # `Clickwrap::Models::Event`.
  def self.zeitwerk_managed_files
    Dir[File.join(CLICKWRAP_LIB, "**", "*.rb")].reject do |path|
      Clickwrap::Engine::ZEITWERK_IGNORED.include?(path.delete_prefix("#{CLICKWRAP_LIB}/"))
    end.sort
  end

  def self.constant_name_for(path)
    relative = path.delete_prefix("#{CLICKWRAP_LIB}/").delete_suffix(".rb")
    relative = relative.delete_prefix("models/concerns/").delete_prefix("models/")

    "Clickwrap::#{relative.split("/").map(&:camelize).join("::")}"
  end

  test "every file Zeitwerk manages defines exactly the constant its path names" do
    files = self.class.zeitwerk_managed_files

    # A guard against this sweep silently becoming a no-op if the layout moves.
    assert_operator files.length, :>=, 50,
                    "found only #{files.length} autoloadable files, so this proves nothing"

    offenders = files.filter_map do |path|
      name = self.class.constant_name_for(path)
      relative = path.delete_prefix("#{Clickwrap::Engine.root}/")

      next "#{relative} defines no #{name}" unless Object.const_defined?(name)

      source = Object.const_source_location(name)&.first
      next if source == path

      "#{name} is expected in #{relative} but is defined in " \
        "#{source&.delete_prefix("#{Clickwrap::Engine.root}/") || "no file"}"
    end

    assert_empty offenders, "Zeitwerk's one-constant-per-file rule is broken:\n#{offenders.join("\n")}"
  end

  test "no constant hitches a ride in a file Zeitwerk manages for another one" do
    # The other direction, and the one that actually bit: a second class added
    # to an existing file resolves perfectly under eager loading and raises
    # NameError the first time a development app refers to it lazily, because
    # Zeitwerk has no file to load it from.
    #
    # Only files the loader MANAGES are held to this. `errors.rb` deliberately
    # defines forty constants and is required explicitly at boot, which is why
    # it is on the ignore list.
    managed = self.class.zeitwerk_managed_files.to_set

    stowaways = Clickwrap.constants.filter_map do |short_name|
      constant = Clickwrap.const_get(short_name)
      next unless constant.is_a?(Module)

      # A namespace module Zeitwerk creates from a DIRECTORY resolves no matter
      # which file happened to write `module X` first, so it is not riding
      # along on anything.
      next if File.directory?(File.join(CLICKWRAP_LIB, short_name.to_s.underscore))

      source = Object.const_source_location("Clickwrap::#{short_name}")&.first
      next unless source && managed.include?(source)
      next if File.basename(source) == "#{short_name.to_s.underscore}.rb"

      "Clickwrap::#{short_name} rides along in " \
        "#{source.delete_prefix("#{Clickwrap::Engine.root}/")}, which Zeitwerk loads for " \
        "another constant — it needs its own file"
    end

    assert_empty stowaways, stowaways.join("\n")
  end

  test "every explicitly required spine file has actually been loaded" do
    # These are `require`d by lib/clickwrap.rb at boot and therefore IGNORED by
    # the loader, so Zeitwerk's naming rule does not apply to them and nothing
    # would notice one silently dropping out of the require list.
    missing = Clickwrap::Engine::ZEITWERK_IGNORED.reject do |file|
      $LOADED_FEATURES.include?(File.join(CLICKWRAP_LIB, file))
    end

    assert_empty missing, "ignored by the autoloader and never required: #{missing.join(", ")}"
  end

  test "every public lifecycle and import entry point names its own keywords" do
    # A bare `**` forward compiles fine, reads fine, and then an editor shows
    # `**` where the argument list should be, a typo'd keyword travels one
    # method deeper before failing, and the gem's public API is documented only
    # in the private method behind it.
    %i[
      withdraw! correct_declaration! renew! change_consent_scope! revoke! supersede!
      exempt! import_external_receipt! import_legacy!
    ].each do |name|
      parameters = Clickwrap.method(name).parameters

      refute parameters.any? { |kind, _| kind == :keyrest },
             "Clickwrap.#{name} forwards ** instead of naming the keywords it accepts"
      assert parameters.any? { |kind, _| %i[key keyreq].include?(kind) },
             "Clickwrap.#{name} accepts no named keywords at all"
    end
  end

  test "the gate registry keeps every gate when controllers register from several threads" do
    # Gates register from controller class bodies, and Rails autoloads — and in
    # development reloads — controllers from more than one thread. A bare Hash
    # written concurrently loses entries, and a lost entry is a gate that
    # quietly stopped being checked. Registry and Identifier already take a
    # lock; this registry does now too.
    before = Clickwrap::ControllerHelpers.registered_gates.keys
    gates = 50.times.map { |index| "ThreadedGateProbe#{index}.requires_clickwrap" }

    gates.map do |gate|
      Thread.new do
        Clickwrap::ControllerHelpers.register_gate(
          :current_terms, remediation_path: "/support/agreements", gate: gate
        )
      end
    end.each(&:join)

    added = Clickwrap::ControllerHelpers.registered_gates.keys - before
    assert_equal gates.length, added.length

    # And the sweep still completes: it snapshots under the same lock and
    # verifies outside it, so nothing re-enters a non-reentrant mutex.
    assert_nothing_raised { Clickwrap::ControllerHelpers.verify_registered_gates! }
  ensure
    gates&.each { |gate| Clickwrap::ControllerHelpers.registered_gates.delete([gate, "current_terms"]) }
  end

  test "the six kinds and their actions are frozen vocabularies" do
    assert_equal 6, Clickwrap::Vocabulary::KINDS.length
    assert Clickwrap::Vocabulary::KINDS.frozen?
    assert Clickwrap::Vocabulary::ACTIONS_FOR_KIND.frozen?
  end
end
