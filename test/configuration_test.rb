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
    assert_equal({ target: "_blank", rel: "noopener" },
                 config.document_link_html_options_with.call(nil))
  end

  test "the default authentication description claims a session only when an actor exists" do
    config = Clickwrap::Configuration.new
    controller_shape = Struct.new(:current_user)

    assert_equal({ method: :authenticated_session },
                 config.describe_authentication_with.call(controller_shape.new(Object.new)))
    assert_equal({}, config.describe_authentication_with.call(controller_shape.new(nil)),
                 "a signup form is not an authenticated session")
    assert_equal({}, config.describe_authentication_with.call(Object.new),
                 "a controller with no authentication at all has nothing to describe — never an error")
  end

  test "publishing rides db:prepare by default, and the opt-out is a boolean" do
    config = Clickwrap::Configuration.new

    assert config.publish_documents_after_database_preparation

    config.publish_documents_after_database_preparation = false
    assert_not config.publish_documents_after_database_preparation

    assert_raises(Clickwrap::ConfigurationError) do
      config.publish_documents_after_database_preparation = "yes"
    end
  end

  test "nothing personal is collected by default" do
    config = Clickwrap::Configuration.new

    assert_not config.record_request_evidence_by_default
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

  test "document link navigation options must be callable" do
    error = assert_raises(Clickwrap::ConfigurationError) do
      Clickwrap.config.document_link_html_options_with = { target: "_blank" }
    end

    assert_match(/document_link_html_options_with/, error.message)
    assert_match(/respond to #call/, error.message)
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

  test "IP-derived application defaults record without reviewed proxy provenance" do
    # Until 0.3.0 this combination refused to boot. It now records the annex
    # with a nil digest, which is itself honest provenance: nobody reviewed a
    # proxy topology, and the receipt does not pretend otherwise. `doctor`
    # still says so out loud (see doctor_test).
    Clickwrap.configure do |config|
      config.trusted_proxy_configuration_digest = nil
      config.record_ip_address_by_default = true
      config.reason_for_recording_ip_addresses_by_default = "Investigate disputed submissions"
      config.delete_recorded_ip_addresses_after = 30.days
    end

    assert Clickwrap.config.validate!
    assert_nil Clickwrap.config.trusted_proxy_configuration_digest

    # Hosts who do review one still get the stronger record, and the setter
    # still refuses anything that is not a complete prefixed digest.
    Clickwrap.configure do |config|
      config.trusted_proxy_configuration_digest =
        Clickwrap.trusted_proxy_configuration_digest_for([IPAddr.new("10.0.0.0/8")])
    end
    assert Clickwrap::Digest.well_formed?(Clickwrap.config.trusted_proxy_configuration_digest)

    error = assert_raises(Clickwrap::ConfigurationError) do
      Clickwrap.config.trusted_proxy_configuration_digest = "TODO: ask infrastructure"
    end
    assert_match(/complete prefixed SHA-2 digest/, error.message)
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

  test "an IP geolocation adapter cannot silently discard request provenance" do
    old_contract_resolver = Class.new do
      def resolve(_ip_address) = nil
      def capabilities = []
    end.new

    error = assert_raises(Clickwrap::ConfigurationError) do
      Clickwrap.config.ip_geolocation_resolver = old_contract_resolver
    end

    assert_match(/resolve\(ip_address, http_request: nil\)/, error.message)
    assert_match(/request-backed providers such as Cloudflare/, error.message)
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

  test "reset! leaves no memoized token verifier behind" do
    # A verifier that outlives a reset goes on signing and accepting tokens
    # under the configuration it was built from. `reset!` used to clear the
    # remediation verifier and not the presentation one; the test suite hid
    # that by resetting it separately in its own setup, which is exactly why
    # nothing caught it.
    Clickwrap::PresentationManifest.verifier
    Clickwrap::RemediationToken.send(:verifier)

    Clickwrap.reset!

    [Clickwrap::PresentationManifest, Clickwrap::RemediationToken].each do |holder|
      refute holder.instance_variable_get(:@verifier),
             "#{holder.name} kept a verifier built before reset!"
    end
  end

  # --- The named escape hatch -------------------------------------------------

  test "turning encryption off is a sentence a reviewer can find, not a false" do
    # The ceremony is the method name, and it survives: `= false` alone still
    # cannot reach the setting. What no longer survives is being asked to
    # phrase the reason twice — the method records the gem's own when the host
    # writes none.
    error = assert_raises(Clickwrap::ConfigurationError) do
      Clickwrap.config.encrypt_recorded_ip_addresses = false
    end

    assert_match(/plain text in your database/, error.message)
    assert_match(/deliberately_store_request_evidence_unencrypted!/, error.message)

    Clickwrap.config.deliberately_store_request_evidence_unencrypted!
    Clickwrap.config.encrypt_recorded_ip_addresses = false

    assert_not Clickwrap.config.encrypt_recorded_ip_addresses
    assert Clickwrap.config.storing_request_evidence_unencrypted?
    assert_equal Clickwrap::Vocabulary::DEFAULT_REASON_FOR_STORING_REQUEST_EVIDENCE_UNENCRYPTED,
                 Clickwrap.config.reason_for_storing_request_evidence_unencrypted
  end

  test "a host's own reason for unencrypted storage stays their own words" do
    Clickwrap.config.deliberately_store_request_evidence_unencrypted!(
      because: "Reviewed: this deployment encrypts at the storage layer"
    )
    Clickwrap.config.encrypt_recorded_browser_user_agents = false

    assert_not Clickwrap.config.encrypt_recorded_browser_user_agents
    assert_match(/storage layer/, Clickwrap.config.reason_for_storing_request_evidence_unencrypted)
  end

  test "encryption is on by default for all three categories, switch or no switch" do
    Clickwrap.configure { |config| config.record_request_evidence_by_default = true }

    assert Clickwrap.config.encrypt_recorded_ip_addresses
    assert Clickwrap.config.encrypt_recorded_browser_user_agents
    assert Clickwrap.config.encrypt_recorded_ip_geolocation
    assert_not Clickwrap.config.storing_request_evidence_unencrypted?
  end

  test "there is no switch whose name hides what it collects" do
    # Deliberately absent. Each of these names either claims a legal outcome no
    # runtime flag can deliver, or describes its collection so vaguely that a
    # reader of the initializer cannot tell what it turns on.
    %i[gdpr_compliant_mode maximum_evidence full_evidence legal_proof
       record_network_context track_everything record_location].each do |name|
      assert_not Clickwrap.config.respond_to?(:"#{name}="), "#{name} must not exist"
      assert_not Clickwrap.config.respond_to?(name), "#{name} must not exist"
    end

    # The one switch that does exist names its own contents, and the reader
    # reports what is actually on rather than a remembered assignment.
    assert_respond_to Clickwrap.config, :record_request_evidence_by_default=
    assert_not Clickwrap.config.record_request_evidence_by_default
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
