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
require_relative "clickwrap/reference"
require_relative "clickwrap/protected_outcome"
require_relative "clickwrap/trusted_proxy_configuration"
require_relative "clickwrap/reviewed_text"
require_relative "clickwrap/ip_geolocation"
require_relative "clickwrap/authority"
require_relative "clickwrap/integrations/organizations_authority"
require_relative "clickwrap/subject_fingerprint"
require_relative "clickwrap/remediation_token"
require_relative "clickwrap/durable_commit_callback"
require_relative "clickwrap/front_matter"
require_relative "clickwrap/document_renderer"
require_relative "clickwrap/document_renderers/markdown"
require_relative "clickwrap/document_renderers/markdown_rails"
require_relative "clickwrap/configuration"
require_relative "clickwrap/macros"

require_relative "clickwrap/engine" if defined?(Rails::Engine)

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
  # The retention class every policy gets unless it names its own with
  # `retain_with`: evidence kept indefinitely, deletion always an explicit,
  # reviewed act. Keeping is reversible; deleting is not.
  DEFAULT_RETENTION_CLASS_KEY = "evidence_kept_indefinitely"
  DOCUMENT_OPTIONS = %i[
    version locale media_type effective_at tenant from content resolver renderer link
  ].freeze

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
      # Every memoized verifier goes with the configuration it was built from.
      # A verifier that outlived a reset keeps signing and accepting tokens
      # under the previous secret, which is the kind of thing a test suite
      # papers over (by resetting it itself) and a console session discovers
      # the hard way.
      RemediationToken.reset_verifier! if defined?(RemediationToken)
      PresentationManifest.reset_verifier! if defined?(PresentationManifest)
      SchemaRequirements.reset! if defined?(SchemaRequirements)
      self
    end

    # --- Registries -----------------------------------------------------------

    def documents = @documents ||= Registry.new(:document)
    def policies = @policies ||= Registry.new(:policy)

    # The registry is seeded with one built-in class: evidence kept
    # indefinitely, nothing scheduled for deletion. It exists so a policy that
    # never says `retain_with` has a real, inspectable retention class instead
    # of a hole — keeping is the reversible default; deletion is the reviewed
    # opt-in. A host wanting deletion clocks declares its own class and names
    # it on the policy. The seed survives every reload (see Registry#clear).
    def retention_classes
      @retention_classes ||= Registry.new(:retention_class) do |registry|
        registry.register(DEFAULT_RETENTION_CLASS_KEY,
                          RetentionClass.new(key: DEFAULT_RETENTION_CLASS_KEY, rules: {}))
      end
    end

    # Declares one immutable document version. Declaring it does not publish it:
    # `bin/rails clickwrap:publish` reads the bytes once, digests them, and
    # freezes a database snapshot. Until then the declaration is a promise about
    # what will be published, and a policy that references an unpublished
    # document fails loudly rather than presenting nothing.
    def document(key, **options)
      unknown = options.keys.map(&:to_sym) - DOCUMENT_OPTIONS
      unless unknown.empty?
        raise DefinitionError,
              "Document #{key.inspect} has unknown option#{"s" if unknown.many?} " \
              "#{unknown.map { |option| "`#{option}:`" }.join(", ")}. Supported options are: " \
              "#{DOCUMENT_OPTIONS.map { |option| "`#{option}:`" }.join(", ")}. Clickwrap never " \
              "ignores document options."
      end

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

    def present(policy_key, **)
      Presenter.new(policy: policy!(policy_key), **).present
    end

    def capture!(policy_key, actor:, subject: nil, tenant: nil, http_request: nil,
                 submission: nil, answers: nil, locale: nil, capture_channel: nil,
                 acting_for: nil, authentication_context: nil, attribution_method: nil,
                 idempotency_key: nil)
      Capture.new(
        policy: policy!(policy_key), actor: actor, subject: subject, tenant: tenant,
        http_request: http_request, submission: submission, answers: answers, locale: locale,
        capture_channel: capture_channel, acting_for: acting_for,
        authentication_context: authentication_context, attribution_method: attribution_method,
        idempotency_key: idempotency_key
      ).capture!
    end

    def capture_and!(policy_key, actor:, subject: nil, tenant: nil, http_request: nil,
                     submission: nil, answers: nil, locale: nil, capture_channel: nil,
                     acting_for: nil, authentication_context: nil, attribution_method: nil,
                     idempotency_key: nil, &)
      Capture.new(
        policy: policy!(policy_key), actor: actor, subject: subject, tenant: tenant,
        http_request: http_request, submission: submission, answers: answers, locale: locale,
        capture_channel: capture_channel, acting_for: acting_for,
        authentication_context: authentication_context, attribution_method: attribution_method,
        idempotency_key: idempotency_key
      ).capture_and!(&)
    end

    # A prospective represented-party flow for records such as a new customer
    # organization. The form binds the record type and a server-owned browser
    # flow before the record exists. This block must return a persisted record
    # of that presented type after creating its host authority relationship;
    # Clickwrap then verifies authority,
    # rebinds the final stable reference, and commits all of it together.
    def create_represented_party!(policy_key, actor:, represented_party:,
                                  represented_party_creation_flow_id:,
                                  subject: nil, tenant: nil, http_request: nil,
                                  submission: nil, answers: nil, locale: nil,
                                  capture_channel: nil, authentication_context: nil,
                                  attribution_method: nil, idempotency_key: nil, &)
      Capture.new(
        policy: policy!(policy_key), actor: actor, subject: subject, tenant: tenant,
        http_request: http_request, submission: submission, answers: answers, locale: locale,
        capture_channel: capture_channel, acting_for: represented_party,
        authentication_context: authentication_context, attribution_method: attribution_method,
        idempotency_key: idempotency_key,
        represented_party_creation_flow_id: represented_party_creation_flow_id
      ).create_represented_party!(&)
    end

    # Signup, modeled honestly: at first render there is no persisted actor, so
    # the presentation binds to a short-lived registration flow, and the account
    # and its evidence commit together. The receipt records account-registration
    # attribution rather than pretending someone was already authenticated.
    #
    # A prospective actor must be new. A public form's typed email address is
    # not proof that its visitor controls an existing account or lead row. Use
    # a distinct pending-request record, confirm the email address, and only
    # then capture for the verified actor through the ordinary authenticated
    # path.
    def register!(policy_key, prospective_actor:, subject: nil, tenant: nil, http_request: nil,
                  submission: nil, answers: nil, locale: nil, capture_channel: nil,
                  acting_for: nil, authentication_context: nil, idempotency_key: nil,
                  registration_flow_id: nil, &)
      Capture.new(
        policy: policy!(policy_key), actor: nil, prospective_actor: prospective_actor,
        subject: subject, tenant: tenant, http_request: http_request, submission: submission,
        answers: answers, locale: locale, capture_channel: capture_channel,
        acting_for: acting_for, authentication_context: authentication_context,
        idempotency_key: idempotency_key, registration_flow_id: registration_flow_id
      ).register!(&)
    end

    # Produces the strict, canonical result snapshot consumed by
    # `record_protected_outcome_with`. Keeping this construction in the gem
    # prevents every host from inventing a subtly different hash contract.
    def protected_outcome(...) = ProtectedOutcome.build(...)

    # Digest the effective proxy rules rather than a prose description of
    # them. The Rails-specific helper includes Rails' actual defaults when the
    # application has not overridden `action_dispatch.trusted_proxies`.
    def trusted_proxy_configuration_digest_for(trusted_proxies)
      TrustedProxyConfiguration.digest_for(trusted_proxies)
    end

    def trusted_proxy_configuration_digest_for_rails_application(application = Rails.application)
      TrustedProxyConfiguration.digest_for_rails_application(application)
    end

    def submission_from(params, ...) = Submission.from_params(params, ...)

    # --- Lifecycle ------------------------------------------------------------
    #
    # Each of these spells out the keywords its target accepts rather than
    # forwarding `**`. A bare forward compiles fine and reads fine, and then an
    # editor shows `**` where the argument list should be, a typo'd keyword
    # travels one method further before failing, and the public API of the gem
    # is documented only in the private method behind it.

    def withdraw!(purpose_key, actor:, because:, tenant: nil, subject: nil,
                  acting_for: nil, http_request: nil)
      Lifecycle.withdraw!(purpose_key, actor: actor, because: because, tenant: tenant,
                                       subject: subject, acting_for: acting_for,
                                       http_request: http_request)
    end

    # Correcting, renewing, and rescoping are new statements by the same
    # person, so each takes the same `submission:` a first capture does: they
    # are captured through a real presentation, not flipped administratively.
    def correct_declaration!(statement_key, actor:, because:, subject: nil, tenant: nil,
                             replaces: nil, acting_for: nil, http_request: nil,
                             submission: nil, answers: nil)
      Lifecycle.correct!(statement_key, actor: actor, because: because, subject: subject,
                                        tenant: tenant, replaces: replaces, acting_for: acting_for,
                                        http_request: http_request, submission: submission,
                                        answers: answers)
    end

    def renew!(statement_key, actor:, because:, subject: nil, tenant: nil,
               acting_for: nil, http_request: nil, submission: nil, answers: nil)
      Lifecycle.renew!(statement_key, actor: actor, because: because, subject: subject,
                                      tenant: tenant, acting_for: acting_for,
                                      http_request: http_request, submission: submission,
                                      answers: answers)
    end

    def change_consent_scope!(statement_key, actor:, because:, subject: nil, tenant: nil,
                              acting_for: nil, http_request: nil, submission: nil, answers: nil)
      Lifecycle.change_consent_scope!(statement_key, actor: actor, because: because,
                                                     subject: subject, tenant: tenant,
                                                     acting_for: acting_for,
                                                     http_request: http_request,
                                                     submission: submission, answers: answers)
    end

    def revoke!(statement_key, actor:, because:, subject: nil, tenant: nil,
                acting_for: nil, http_request: nil)
      Lifecycle.revoke!(statement_key, actor: actor, because: because, subject: subject,
                                       tenant: tenant, acting_for: acting_for,
                                       http_request: http_request)
    end

    def supersede!(statement_key, actor:, because: nil, subject: nil, tenant: nil,
                   acting_for: nil, http_request: nil)
      Lifecycle.supersede!(statement_key, actor: actor, because: because, subject: subject,
                                          tenant: tenant, acting_for: acting_for,
                                          http_request: http_request)
    end

    # An explicitly recorded system exemption. Seeds, imports, invitations, and
    # service accounts must never "accept" by omitting a browser parameter or by
    # fabricating a human click. An exemption says plainly that no human action
    # occurred, records who created it and why, and never satisfies
    # `agreed_to?` — it answers the separate `exempted_from?` question.
    def exempt!(policy_key, actor:, because:, subject: nil, tenant: nil)
      Lifecycle.exempt!(policy_key, actor: actor, because: because, subject: subject,
                                    tenant: tenant)
    end

    # Captures evidence and commits a pending outbox row in one local
    # transaction, for an action that has to cross a system boundary. This is a
    # distributed reliability protocol, not a cross-system ACID transaction —
    # see Clickwrap::Services::AuthorizeExternalAction for exactly what it does
    # and does not promise.
    def authorize_external_action!(policy_key,
                                   after_pending_action_is_saved_inside_transaction: nil,
                                   **,
                                   &local_transaction_block)
      if after_pending_action_is_saved_inside_transaction && local_transaction_block
        raise ArgumentError,
              "Pass either after_pending_action_is_saved_inside_transaction: or a block, not both."
      end

      local_transaction_hook =
        after_pending_action_is_saved_inside_transaction || local_transaction_block

      Services::AuthorizeExternalAction.new(
        policy: policy!(policy_key),
        after_pending_action_is_saved_inside_transaction: local_transaction_hook,
        **
      ).call
    end

    def import_external_receipt!(policy_key, actor:, provider_name:, provider_event_id:,
                                 provider_receipt: nil, verified_with: nil, verified_at: nil,
                                 occurred_at: nil, subject: nil, tenant: nil, because: nil,
                                 statements: nil)
      Import::ExternalReceipt.new(
        policy: policy!(policy_key), actor: actor, provider_name: provider_name,
        provider_event_id: provider_event_id, provider_receipt: provider_receipt,
        verified_with: verified_with, verified_at: verified_at, occurred_at: occurred_at,
        subject: subject, tenant: tenant, because: because, statements: statements
      ).import!
    end

    def import_legacy!(policy_key, actor:, occurred_at:, because:, known: {}, unknown: [],
                       dry_run: false, subject: nil, tenant: nil, statements: nil,
                       capture_channel: "imported_provider", source: nil, counts_as_current: true)
      Import::Legacy.new(
        policy: policy!(policy_key), actor: actor, occurred_at: occurred_at, because: because,
        known: known, unknown: unknown, dry_run: dry_run, subject: subject, tenant: tenant,
        statements: statements, capture_channel: capture_channel, source: source,
        counts_as_current: counts_as_current
      ).import!
    end

    # --- Verification and gating ---------------------------------------------

    def verify(policy_or_event, **) = Verification.verify(policy_or_event, **)

    def require!(policy_key, **)
      result = verify(policy_key, **)
      raise VerificationFailed, result unless result.success?

      result
    end

    def current?(policy_key, **) = verify(policy_key, **).success?

    # True when the actor needs to complete this policy: either they have no
    # current evidence, or a newer required document version has published since
    # they last acted. The application decides which change is material;
    # Clickwrap enforces the rule it is given.
    def required?(policy_key, **) = !current?(policy_key, **)

    def receipt(event_id) = Receipt.find(event_id)

    def export_receipt(receipt, **) = Receipt.export(receipt, **)

    # Retry optional timestamp/anchor work that left no immutable result after a
    # committed event. This is intentionally explicit: it can call external
    # providers, so applications normally run it from a scheduled job or the
    # matching rake task rather than hiding it in a read path.
    def reconcile_missing_integrity_attestations!(scope: Event.all, retry_failed_attestations: false)
      Integrity::AttestationReconciler.new(
        scope: scope,
        retry_failed_attestations: retry_failed_attestations
      ).call
    end

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

# The framework-integration modules are spine files, not autoloaded code: the
# engine's `on_load(:action_view)` / `on_load(:action_controller)` hooks run
# IMMEDIATELY when a host's other gems have already loaded that framework by
# the time Clickwrap's initializers register — which can be before the host's
# autoloader can serve these constants. They must exist the moment the engine
# file does.
require_relative "clickwrap/form_builder_extensions"
require_relative "clickwrap/view_helpers"
require_relative "clickwrap/controller_helpers"
require_relative "clickwrap/registration"
