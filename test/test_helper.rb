# frozen_string_literal: true

# SimpleCov must be loaded before any application code
# (configuration is auto-loaded from the .simplecov file).
require "simplecov"

# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

# Devise is a test-only compatibility dependency. Its Railtie must register
# before the dummy application initializes; requiring it from one test file
# makes the result depend on whether that file happened to load first. The
# Clickwrap runtime never requires Devise and the gemspec does not depend on it.
require "devise"

require File.expand_path("dummy/config/environment.rb", __dir__)
ActiveRecord::Migrator.migrations_paths = [
  File.expand_path("dummy/db/migrate", __dir__)
]

# Auto-migrate so a plain `bundle exec rake test` works on a fresh checkout
# (CI also runs db:migrate explicitly; this is idempotent either way).
ActiveRecord::MigrationContext.new(ActiveRecord::Migrator.migrations_paths).migrate

require "rails/test_help"
require "minitest/mock"
require "mocha/minitest"

require "clickwrap/test_helpers"

# Filter out Minitest backtrace while allowing backtrace from other libraries
# to be shown.
Minitest.backtrace_filter = Minitest::BacktraceFilter.new

module ActiveSupport
  class TestCase
    include ActiveJob::TestHelper
    include Clickwrap::TestHelpers

    # The dummy host's initializer wiring, restated here because `reset!` wipes
    # it. Every test therefore starts from the same known configuration, and a
    # test that changes one can do so without leaking into the next.
    DUMMY_CONFIGURATION = lambda do |config|
      config.actor_class_name = "User"
      config.current_actor_method_name = :current_user
      config.parent_controller_class_name = "ApplicationController"
      config.application_version = -> { "dummy-test" }
      config.trusted_proxy_configuration_digest =
        Clickwrap::Digest.digest("dummy-host-reviewed-trusted-proxy-configuration-v1")
      config.ip_geolocation_resolver = DummyIpGeolocationResolver.new
      config.find_current_tenant_with = lambda do |controller|
        controller.current_organization if controller.respond_to?(:current_organization)
      end

      config.authorize_receipt_access_with = lambda do |controller, receipt|
        controller.current_user&.clickwrap_actor_reference == receipt.actor_reference
      end

      config.authorize_unredacted_request_evidence_access_with = lambda do |requested_by, _receipt, because|
        requested_by.respond_to?(:security_operator?) && requested_by.security_operator? && because.present?
      end

      config.authorize_clickwrap_remediation_subject_with = lambda do |actor:, subject:, policy:, controller:|
        subject.nil? || (subject.respond_to?(:user_id) && subject.user_id == actor&.id)
      end

      config.authorize_clickwrap_remediation_represented_party_with =
        lambda do |actor:, represented_party:, policy:, controller:|
          represented_party.nil? || controller.current_organization == represented_party
        end

      config.calculate_retention_time_for :regulated_evidence_retention_ends do |event|
        [
          event.recorded_at_by_server + 5.years,
          event.subject.respond_to?(:liquidated_at) ? event.subject.liquidated_at&.+(3.years) : nil
        ].compact.max
      end

      config.calculate_retention_time_for :security_evidence_retention_ends do |event|
        event.recorded_at_by_server + 2.years
      end
    end

    setup do
      # Start every test from a known configuration so hooks, resolvers, and
      # request-evidence defaults never leak between tests — and reload the
      # dummy's declarations, because `reset!` clears the registries too.
      Clickwrap.reset!
      Clickwrap.configure(&DUMMY_CONFIGURATION)
      Clickwrap::Services::LoadPolicies.new(root: Rails.root.to_s, paths: ["config/clickwrap.rb"]).call
      Clickwrap::Testing.reset! if defined?(Clickwrap::Testing)

      publish_clickwrap_documents!
    end

    teardown do
      Clickwrap.reset!
      Clickwrap::Testing.reset! if defined?(Clickwrap::Testing)
    end

    # --- Data helpers ---------------------------------------------------------

    def create_user(email: "person-#{SecureRandom.hex(4)}@example.com", **attributes)
      User.create!(email: email, name: "Test Person", **attributes)
    end

    def create_security_operator
      create_user(role: "security_operator")
    end

    def create_organization(name: "Acme #{SecureRandom.hex(3)}")
      Organization.create!(name: name)
    end

    def create_withdrawal(user: nil, amount_cents: 25_000, covered_order_ids: "1,2,3")
      Withdrawal.create!(user: user || create_user, amount_cents: amount_cents,
                         covered_order_ids: covered_order_ids)
    end

    # Counts the queries a block asks Active Record for.
    #
    # Query-cache hits are COUNTED on purpose. An N+1 whose rows all resolve to
    # the same record is served from the cache inside one request and would
    # otherwise measure as free here, while costing a real round trip each in
    # production the moment the rows differ. Schema reflection and transaction
    # control are not queries a reader would recognize, so they are left out.
    # `matching:` narrows the count to queries whose SQL matches, which is how
    # a test pins the cost of one concern without also pinning every unrelated
    # query that happens to share the request.
    def count_queries(matching: nil)
      queries = 0
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        next if %w[SCHEMA TRANSACTION].include?(payload[:name])
        next if matching && !payload[:sql].to_s.match?(matching)

        queries += 1
      end

      yield
      queries
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    # Publishing is idempotent, so calling it in every setup costs one digest
    # comparison per document and keeps each test independent of ordering.
    def publish_clickwrap_documents!
      Clickwrap.publish!
    end

    # Republishes a document under a NEW version label, which is how a real
    # application makes existing evidence stale for a `require_current_version`
    # policy.
    def publish_new_document_version!(key, version:, content: nil)
      definition = Clickwrap.documents.values.find { |candidate| candidate.key == key.to_s }

      Clickwrap.document(
        key,
        version: version,
        locale: definition.locale,
        content: content || "#{definition.read_bytes}\n\nRevised #{version}."
      )

      Clickwrap.publish!
    end
  end
end

module ActionDispatch
  class IntegrationTest
    # Act as +user+ for subsequent requests (see the dummy SessionsController).
    def login_as(user, organization: nil)
      post "/test_login", params: { user_id: user.id, organization_id: organization&.id }
      assert_response :no_content
    end
  end
end
