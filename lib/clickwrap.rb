# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/string/inflections"
require "active_support/core_ext/numeric/time"
require "active_support/core_ext/object/blank"

require_relative "clickwrap/version"
require_relative "clickwrap/errors"
require_relative "clickwrap/vocabulary"
require_relative "clickwrap/canonical_json"
require_relative "clickwrap/digest"
require_relative "clickwrap/identifier"
require_relative "clickwrap/configuration"
require_relative "clickwrap/macros"

require_relative "clickwrap/engine" if defined?(::Rails::Engine)

# == Clickwrap
#
# The evidence-and-assent layer for Rails: versioned agreements,
# acknowledgments, consent, declarations, attestations, and authorizations,
# captured with the exact content and presentation they were offered under, and
# committed in the same transaction as the action they authorize.
#
# The public surface is intentionally small:
#
#   Clickwrap.configure { |config| ... }   # one block, in an initializer
#   Clickwrap.document :terms, ...         # immutable versioned content
#   Clickwrap.policy :signup do ... end    # what the server offers and accepts
#   Clickwrap.retention :ordinary do ...   # how long each part is kept
#
#   has_clickwraps                         # on the model that can act
#   form.clickwrap :signup, submit: "..."  # render the controls and the action
#
#   Clickwrap.capture!(:signup, actor:, http_request:, submission:)
#   Clickwrap.capture_and!(:withdrawal, ...) { withdrawal.submit! }
#   user.clickwraps.agreed_to?(:terms)
#   Clickwrap.verify(:withdrawal, actor:, subject:)
#
# What this gem does is evidence mechanics. What it does not do is decide
# whether your agreement is enforceable, whether consent is the right lawful
# basis, whether a document change is material, who someone really is, or how
# long you must keep anything. Those belong to the application and its counsel,
# and no configuration flag here can stand in for them.
module Clickwrap
  # The Minitest helpers hosts include in their own suite. Autoloaded rather
  # than required at boot: a test helper has no business being resident in a
  # production process, and a host that never writes a Clickwrap test never
  # loads the file.
  #
  #   class ActiveSupport::TestCase
  #     include Clickwrap::TestHelpers
  #   end
  autoload :TestHelpers, "clickwrap/test_helpers"

  class << self
    # --- Configuration --------------------------------------------------------

    def config
      @config ||= Configuration.new
    end

    alias configuration config

    def configure
      yield config if block_given?
      config.validate!
      config
    end

    # Reset all global state. Used by the test suite to keep examples isolated;
    # also handy in a console when experimenting with configuration.
    def reset!
      @config = Configuration.new
      @documents = nil
      @policies = nil
      @retention_classes = nil
      self
    end

    # --- Registries -----------------------------------------------------------

    def documents = @documents ||= Registry.new(:document)
    def policies = @policies ||= Registry.new(:policy)
    def retention_classes = @retention_classes ||= Registry.new(:retention_class)

    # Declares one immutable document version. Declaring it does not publish it:
    # `bin/rails clickwrap:publish` reads the bytes once, digests them, and
    # freezes a database snapshot. Until then the declaration is a promise about
    # what will be published, and a policy that references an unpublished
    # document fails loudly rather than presenting nothing.
    def document(key, **options)
      definition = DocumentDefinition.new(key: key, **options)
      documents.register(definition.identity, definition)
      definition
    end

    # Declares a server-owned policy. Compiles immediately so a mistake is a
    # boot failure with a sentence explaining it, not a surprise at 3am.
    def policy(key, &block)
      raise DefinitionError, "Clickwrap.policy needs a block" unless block

      builder = DSL::PolicyBuilder.new(key)
      builder.instance_eval(&block)
      compiled = builder.compile

      policies.register(compiled.key, compiled)
      compiled
    end

    # Declares a retention class. Clickwrap does not choose retention periods
    # and cannot tell you whether yours are right; it makes a reviewed decision
    # executable, auditable, and separable — the core event's schedule is
    # independent of the optional personal request evidence attached to it.
    def retention(key, &block)
      raise DefinitionError, "Clickwrap.retention needs a block" unless block

      builder = DSL::RetentionBuilder.new(key)
      builder.instance_eval(&block)
      compiled = builder.compile

      retention_classes.register(compiled.key, compiled)
      compiled
    end

    def policy!(key)
      policies.fetch(key.to_s) do
        raise UnknownPolicyError,
              "No policy named #{key.inspect}. Defined policies: " \
              "#{policies.keys.sort.join(", ").presence || "(none)"}. Policies are declared with " \
              "`Clickwrap.policy #{key.inspect} do ... end`, conventionally in config/clickwrap.rb."
      end
    end

    def retention_class!(key)
      retention_classes.fetch(key.to_s) do
        raise UnknownRetentionClassError,
              "No retention class named #{key.inspect}. Defined classes: " \
              "#{retention_classes.keys.sort.join(", ").presence || "(none)"}."
      end
    end

    def document_definitions_for(key, tenant: nil)
      documents.values.select do |definition|
        definition.key == key.to_s && definition.tenant_key == tenant&.to_s
      end
    end

    # --- Presentation and capture --------------------------------------------

    def present(policy_key, **options)
      Presenter.new(policy: policy!(policy_key), **options).present
    end

    def capture!(policy_key, **options)
      Capture.new(policy: policy!(policy_key), **options).capture!
    end

    def capture_and!(policy_key, **options, &block)
      Capture.new(policy: policy!(policy_key), **options).capture_and!(&block)
    end

    # Signup, modeled honestly: at first render there is no persisted actor, so
    # the presentation binds to a short-lived registration flow, and the account
    # and its evidence commit together. The receipt records account-registration
    # attribution rather than pretending someone was already authenticated.
    def register!(policy_key, prospective_actor:, **options, &block)
      Capture.new(policy: policy!(policy_key), actor: nil, prospective_actor:, **options)
             .register!(&block)
    end

    def submission_from(params, ...) = Submission.from_params(params, ...)

    # --- Lifecycle ------------------------------------------------------------

    def withdraw!(purpose_key, **options) = Lifecycle.withdraw!(purpose_key, **options)
    def correct_declaration!(statement_key, **options) = Lifecycle.correct!(statement_key, **options)
    def renew!(statement_key, **options) = Lifecycle.renew!(statement_key, **options)
    def revoke!(statement_key, **options) = Lifecycle.revoke!(statement_key, **options)
    def supersede!(statement_key, **options) = Lifecycle.supersede!(statement_key, **options)

    # An explicitly recorded system exemption. Seeds, imports, invitations, and
    # service accounts must never "accept" by omitting a browser parameter or by
    # fabricating a human click. An exemption says plainly that no human action
    # occurred, records who created it and why, and never satisfies
    # `agreed_to?` — it answers the separate `exempted_from?` question.
    def exempt!(policy_key, **options) = Lifecycle.exempt!(policy_key, **options)

    # Captures evidence and commits a pending outbox row in one local
    # transaction, for an action that has to cross a system boundary. This is a
    # distributed reliability protocol, not a cross-system ACID transaction —
    # see Clickwrap::Services::AuthorizeExternalAction for exactly what it does
    # and does not promise.
    def authorize_external_action!(policy_key, **options)
      Services::AuthorizeExternalAction.new(policy: policy!(policy_key), **options).call
    end

    def import_external_receipt!(policy_key, **options)
      Import::ExternalReceipt.new(policy: policy!(policy_key), **options).import!
    end

    def import_legacy!(policy_key, **options)
      Import::Legacy.new(policy: policy!(policy_key), **options).import!
    end

    # --- Verification and gating ---------------------------------------------

    def verify(policy_or_event, **options) = Verification.verify(policy_or_event, **options)

    def require!(policy_key, **options)
      result = verify(policy_key, **options)
      raise VerificationFailed, result unless result.success?

      result
    end

    def current?(policy_key, **options) = verify(policy_key, **options).success?

    # True when the actor needs to complete this policy: either they have no
    # current evidence, or a newer required document version has published since
    # they last acted. The application decides which change is material;
    # Clickwrap enforces the rule it is given.
    def required?(policy_key, **options) = !current?(policy_key, **options)

    def receipt(event_id) = Receipt.find(event_id)

    def export_receipt(receipt, **options) = Receipt.export(receipt, **options)

    # --- Disposition ----------------------------------------------------------

    def delete_recorded_ip_address!(receipt, because:)
      Retention::Disposition.delete_field!(receipt, :ip_address, because:)
    end

    def delete_recorded_browser_user_agent!(receipt, because:)
      Retention::Disposition.delete_field!(receipt, :browser_user_agent, because:)
    end

    def delete_recorded_ip_geolocation!(receipt, because:)
      Retention::Disposition.delete_field!(receipt, :ip_geolocation, because:)
    end

    # --- Actors ---------------------------------------------------------------

    # A stable opaque identifier for someone who is not a persisted record. The
    # host owns the identifier and any later account linking. An IP address is
    # not an actor identifier and Clickwrap will not accept one here.
    def anonymous_actor(identifier) = AnonymousActor.new(identifier)

    # A named non-human actor, for seeds, imports, and background processes.
    def system_actor(name) = SystemActor.new(name)

    # --- Publishing -----------------------------------------------------------

    def publish!(dry_run: false) = Services::PublishDocuments.new(dry_run:).call

    def doctor = Doctor.new.report

    # --- Internals ------------------------------------------------------------

    def gem_version = VERSION
    def canonical_schema_version = CANONICAL_SCHEMA_VERSION

    # The server's own clock, used for every recorded time. It is described in
    # receipts as exactly that — time recorded by the application server — and
    # never as trusted time, which is a different thing supplied by a different
    # kind of provider.
    def now = Time.now.utc

    def logger
      defined?(::Rails) && ::Rails.respond_to?(:logger) ? ::Rails.logger : nil
    end

    # Post-commit hooks are observers, never authorization. A failure here is
    # reported and swallowed, because the evidence and the action it protected
    # have already committed and nothing an analytics call does may undo them.
    def report_after_commit_failure(error, event)
      config.report_after_commit_failure_with.call(error, event)
    rescue StandardError => error
      logger&.error("[clickwrap] after-commit failure reporter itself raised: #{error.class}")
      nil
    end
  end
end

require_relative "clickwrap/registry"
require_relative "clickwrap/localized_text"
require_relative "clickwrap/document_definition"
require_relative "clickwrap/statement"
require_relative "clickwrap/request_evidence_policy"
require_relative "clickwrap/policy"
require_relative "clickwrap/retention_class"
require_relative "clickwrap/dsl/policy_builder"
require_relative "clickwrap/dsl/retention_builder"
