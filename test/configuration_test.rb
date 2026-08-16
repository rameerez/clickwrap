# frozen_string_literal: true

require "test_helper"

# The configuration object is the main thing a host ever reads about this gem,
# so its defaults, its refusals, and the sentences it refuses in are all part of
# the public contract.
class ConfigurationTest < ActiveSupport::TestCase
  test "delightful defaults work untouched" do
    config = Clickwrap::Configuration.new

    assert_equal "User", config.actor_class_name
    assert_equal :current_user, config.current_actor_method_name
    assert_equal "ApplicationController", config.parent_controller_class_name
    assert_equal :database, config.store_document_contents_in
    assert_equal :sha256, config.digest_canonical_receipts_with
    assert_equal 2.hours, config.presentation_valid_for
    assert config.raise_on_missing_translation
    assert_nil config.chain_event_history_with
    assert_nil config.anchor_event_history_with
    assert_nil config.timestamp_receipts_with
    assert_nil config.ip_geolocation_resolver
  end

  test "nothing personal is collected by default" do
    config = Clickwrap::Configuration.new

    assert_not config.record_ip_address_by_default
    assert_not config.record_browser_user_agent_by_default
    assert_empty config.enabled_default_ip_geolocation_fields
    assert_not config.records_any_request_evidence_by_default?
    assert_not config.fail_capture_when_ip_geolocation_is_unavailable
  end

  test "raw values are encrypted by default and there is no keep-forever default" do
    config = Clickwrap::Configuration.new

    assert config.encrypt_recorded_ip_addresses
    assert config.encrypt_recorded_browser_user_agents
    assert config.encrypt_recorded_ip_geolocation

    # nil means "every policy that enables the field supplies its own rule",
    # which is a different and safer thing from "keep it indefinitely".
    assert_nil config.delete_recorded_ip_addresses_after
    assert_nil config.delete_recorded_browser_user_agents_after
    assert_nil config.delete_recorded_ip_geolocation_after
  end

  test "hooks default to no-ops that accept their arguments" do
    config = Clickwrap::Configuration.new

    assert_nil config.after_event_is_committed.call(nil)
    assert_nil config.report_after_commit_failure_with.call(nil, nil)
    assert_nil config.find_current_tenant_with.call(nil)
    assert_equal({}, config.snapshot_actor_with.call(nil))
    assert_equal({}, config.describe_authentication_with.call(nil))
    assert_not config.authorize_receipt_access_with.call(nil, nil)
    assert_not config.authorize_unredacted_request_evidence_access_with.call(nil, nil, nil)
  end

  test "configure yields, validates, and returns the config" do
    result = Clickwrap.configure { |config| config.actor_class_name = "User" }

    assert_same Clickwrap.config, result
    assert_same Clickwrap.config, Clickwrap.configuration
  end

  # --- Refusals ---------------------------------------------------------------

  test "a blank class name is refused at the assignment line" do
    assert_raises(Clickwrap::ConfigurationError) { Clickwrap.config.actor_class_name = "" }
    assert_raises(Clickwrap::ConfigurationError) { Clickwrap.config.actor_class_name = nil }
  end

  test "a class object is accepted and stored as its name, so autoloading is not forced" do
    Clickwrap.config.actor_class_name = User

    assert_equal "User", Clickwrap.config.actor_class_name
    assert_equal User, Clickwrap.config.actor_class
  end

  test "an unknown document store is refused by name" do
    error = assert_raises(Clickwrap::ConfigurationError) do
      Clickwrap.config.store_document_contents_in = :s3
    end

    assert_match(/:database/, error.message)
    assert_match(/:active_storage/, error.message)
    assert_match(/URL alone is never a document version/, error.message)
  end

  test "an unsupported digest algorithm is refused" do
    assert_raises(Clickwrap::ConfigurationError) { Clickwrap.config.digest_canonical_receipts_with = :md5 }
  end

  test "a non-callable hook is refused" do
    error = assert_raises(Clickwrap::ConfigurationError) { Clickwrap.config.after_event_is_committed = :nope }

    assert_match(/must respond to #call/, error.message)
  end

  test "a non-duration presentation window is refused" do
    assert_raises(Clickwrap::ConfigurationError) { Clickwrap.config.presentation_valid_for = "soon" }
    Clickwrap.config.presentation_valid_for = 30.minutes
    assert_equal 30.minutes, Clickwrap.config.presentation_valid_for
  end

  test "a retention period that is not in the future is refused" do
    assert_raises(Clickwrap::ConfigurationError) { Clickwrap.config.delete_recorded_ip_addresses_after = 0.days }
    assert_raises(Clickwrap::ConfigurationError) { Clickwrap.config.delete_recorded_ip_addresses_after = "90 days" }

    Clickwrap.config.delete_recorded_ip_addresses_after = nil
    assert_nil Clickwrap.config.delete_recorded_ip_addresses_after
  end

  test "a boolean setting refuses a truthy non-boolean" do
    error = assert_raises(Clickwrap::ConfigurationError) { Clickwrap.config.record_ip_address_by_default = "yes" }

    assert_match(/must be true or false/, error.message)
  end

  test "IP-derived application defaults require reviewed proxy provenance" do
    error = assert_raises(Clickwrap::ConfigurationError) do
      Clickwrap.configure do |config|
        config.trusted_proxy_configuration_digest = nil
        config.record_ip_address_by_default = true
        config.reason_for_recording_ip_addresses_by_default = "Investigate disputed submissions"
        config.delete_recorded_ip_addresses_after = 30.days
      end
    end

    assert_match(/trusted_proxy_configuration_digest/, error.message)
    assert_match(/does not claim that decision was correct/, error.message)

    Clickwrap.configure do |config|
      config.trusted_proxy_configuration_digest =
        Clickwrap.trusted_proxy_configuration_digest_for([IPAddr.new("10.0.0.0/8")])
    end
    assert Clickwrap.config.validate!
  end

  test "trusted proxy provenance digests the effective rules rather than prose" do
    first = Clickwrap.trusted_proxy_configuration_digest_for(
      [IPAddr.new("10.0.0.0/8"), /\A192\.0\.2\./]
    )
    reordered = Clickwrap.trusted_proxy_configuration_digest_for(
      [/\A192\.0\.2\./, IPAddr.new("10.0.0.0/8")]
    )
    changed = Clickwrap.trusted_proxy_configuration_digest_for(
      [IPAddr.new("10.0.0.0/16"), /\A192\.0\.2\./]
    )

    assert Clickwrap::Digest.well_formed?(first)
    assert_equal first, reordered, "proxy rule order is not semantically meaningful"
    assert_not_equal first, changed
  end

  test "the Rails helper digests configured proxies or the actual Rails defaults" do
    digest = Clickwrap.trusted_proxy_configuration_digest_for_rails_application(Rails.application)

    assert Clickwrap::Digest.well_formed?(digest)
  end

  test "an adapter that does not implement its contract is refused by method name" do
    error = assert_raises(Clickwrap::ConfigurationError) { Clickwrap.config.ip_geolocation_resolver = Object.new }

    assert_match(/must respond to #resolve/, error.message)
  end

  # --- Retention calculations -------------------------------------------------

  test "an unregistered retention calculation is refused with the name it was asked for" do
    error = assert_raises(Clickwrap::ConfigurationError) do
      Clickwrap.config.resolve_retention_time(:nobody_registered_this, nil)
    end

    assert_match(/nobody_registered_this/, error.message)
    assert_match(/calculate_retention_time_for/, error.message)
  end

  test "a retention calculation needs a block" do
    assert_raises(Clickwrap::ConfigurationError) { Clickwrap.config.calculate_retention_time_for(:x) }
  end

  test "the dummy host's calculations are registered" do
    assert_includes Clickwrap.config.retention_time_calculator_names, :regulated_evidence_retention_ends
    assert_includes Clickwrap.config.retention_time_calculator_names, :security_evidence_retention_ends
  end

  # --- Actor references -------------------------------------------------------

  test "the default actor reference is a GlobalID, which outlives the row" do
    user = create_user

    assert_equal user.to_gid.to_s, Clickwrap.config.identify_actor_with.call(user)
  end

  test "the default actor reference works when a minimal Rails host does not load GlobalID" do
    actor_class = Class.new do
      attr_reader :id

      def initialize(id)
        @id = id
      end
    end
    actor_class.define_singleton_method(:name) { "MinimalActor" }
    actor = actor_class.new(42)

    assert_not_respond_to actor, :to_gid
    assert_equal "MinimalActor/42", Clickwrap.config.identify_actor_with.call(actor)
  end

  test "a host can override the reference on the model without touching the initializer" do
    user = create_user
    user.define_singleton_method(:clickwrap_actor_reference) { "host-owned-reference" }

    assert_equal "host-owned-reference", Clickwrap.config.identify_actor_with.call(user)
  end

  test "literal actor references remain usable without pretending they are model instances" do
    assert_equal "external/actor-123", Clickwrap::Reference.actor("external/actor-123")
    assert_equal "external_actor", Clickwrap::Reference.actor(:external_actor)
  end

  test "reset! restores every default" do
    Clickwrap.config.actor_class_name = "Organization"
    Clickwrap.reset!

    assert_equal "User", Clickwrap.config.actor_class_name
  end

  # --- The named escape hatch -------------------------------------------------

  test "turning encryption off is a sentence a reviewer can find, not a false" do
    error = assert_raises(Clickwrap::ConfigurationError) do
      Clickwrap.config.encrypt_recorded_ip_addresses = false
    end

    assert_match(/plain text in your database/, error.message)
    assert_match(/deliberately_store_request_evidence_unencrypted!/, error.message)

    assert_raises(Clickwrap::ConfigurationError) do
      Clickwrap.config.deliberately_store_request_evidence_unencrypted!(because: "  ")
    end

    Clickwrap.config.deliberately_store_request_evidence_unencrypted!(
      because: "Reviewed: this deployment encrypts at the storage layer"
    )
    Clickwrap.config.encrypt_recorded_ip_addresses = false

    assert_not Clickwrap.config.encrypt_recorded_ip_addresses
    assert Clickwrap.config.storing_request_evidence_unencrypted?
    assert_match(/storage layer/, Clickwrap.config.reason_for_storing_request_evidence_unencrypted)
  end

  test "there is no runtime compliance or profile switch" do
    # Deliberately absent. An option that enables a category of personal data as
    # a side effect of something else is the thing this gem exists not to do.
    %i[gdpr_compliant_mode maximum_evidence full_evidence legal_proof
       record_network_context track_everything record_location].each do |name|
      assert_not Clickwrap.config.respond_to?(:"#{name}="), "#{name} must not exist"
      assert_not Clickwrap.config.respond_to?(name), "#{name} must not exist"
    end
  end

  test "every IP-geolocation field has its own separately named setting" do
    Clickwrap::Vocabulary::IP_GEOLOCATION_DATA_FIELDS.each do |field|
      assert Clickwrap.config.respond_to?(:"record_ip_geolocation_#{field}_by_default"),
             "#{field} has no reader"
      assert Clickwrap.config.respond_to?(:"record_ip_geolocation_#{field}_by_default="),
             "#{field} has no setter"
    end
  end
end
