# frozen_string_literal: true

require_relative "errors"

module Clickwrap
  # The single configuration object the host populates in
  # `config/initializers/clickwrap.rb` via `Clickwrap.configure do |config| ... end`.
  #
  # Design rules:
  #   - Config is read AT THE POINT OF USE, not frozen at boot. Class names are
  #     stored as strings and constantized lazily, so the initializer works no
  #     matter when the app loads (the User model may not exist yet at boot).
  #   - Validating setters normalize their input and raise a plain-English
  #     ConfigurationError on a bad value — failing at the assignment line
  #     rather than at 3am with a NoMethodError. `validate!` runs once more at
  #     the end of `configure` for the cross-field checks.
  #   - Every hook defaults to a no-op, so the gem works untouched and a host
  #     wires hooks only as needed.
  #   - Nothing here collects personal data by default. Every `record_*` flag
  #     starts false, and turning one on without a purpose and a retention
  #     decision is a configuration error, not a warning.
  #
  # One setting deserves its own note: there is deliberately no
  # `gdpr_compliant_mode`, `maximum_evidence`, `full_evidence`, or
  # `legal_proof`. An option that silently enables a category of personal data
  # is exactly the thing this gem exists not to do, and no runtime flag can
  # make a legal determination on your behalf.
  class Configuration
    DOCUMENT_STORES = %i[database active_storage resolver].freeze
    DIGEST_ALGORITHMS = %i[sha256 sha384 sha512].freeze

    # The readers are grouped by section on purpose, and kept that way even
    # though rubocop would happily collapse them into one line. The initializer
    # this class backs is the main thing a host reads about Clickwrap, and the
    # shape of these groups is the shape of that file.
    #
    # --- Identity -------------------------------------------------------------
    attr_reader :actor_class_name, :current_actor_method_name, :parent_controller_class_name
    attr_reader :find_current_tenant_with, :identify_actor_with, :snapshot_actor_with
    attr_reader :describe_authentication_with

    # --- Documents and policies -----------------------------------------------
    attr_reader :store_document_contents_in, :document_renderer, :document_resolver
    attr_accessor :policy_paths

    attr_reader :raise_on_missing_translation

    # --- Presentation ---------------------------------------------------------
    attr_reader :presentation_valid_for

    # --- Integrity ------------------------------------------------------------
    attr_reader :digest_canonical_receipts_with, :chain_event_history_with
    attr_reader :anchor_event_history_with, :timestamp_receipts_with
    attr_reader :application_version, :template_version

    # --- Authorization --------------------------------------------------------
    attr_reader :authorize_receipt_access_with, :authorize_unredacted_request_evidence_access_with

    # --- Request evidence: what is recorded by default ------------------------
    #
    # One reader per IP-geolocation field, spelled out rather than generated,
    # because each is a separate decision about what to keep about someone's
    # network context and each should be greppable by its own name.
    attr_reader :record_ip_address_by_default, :record_browser_user_agent_by_default
    attr_reader :record_ip_geolocation_country_by_default,
                :record_ip_geolocation_region_by_default,
                :record_ip_geolocation_city_by_default,
                :record_ip_geolocation_postal_code_by_default,
                :record_ip_geolocation_latitude_and_longitude_by_default,
                :record_ip_geolocation_timezone_by_default,
                :record_ip_geolocation_continent_by_default,
                :record_ip_geolocation_metro_code_by_default,
                :record_ip_geolocation_accuracy_radius_in_kilometers_by_default

    # --- Request evidence: why, how long, and how it is protected -------------
    attr_accessor :reason_for_recording_ip_addresses_by_default,
                  :reason_for_recording_browser_user_agents_by_default,
                  :reason_for_recording_ip_geolocation_by_default,
                  :legal_basis_reference_for_recording_ip_addresses_by_default,
                  :legal_basis_reference_for_recording_browser_user_agents_by_default,
                  :legal_basis_reference_for_recording_ip_geolocation_by_default,
                  :review_default_request_evidence_configuration_on

    attr_reader :encrypt_recorded_ip_addresses, :encrypt_recorded_browser_user_agents,
                :encrypt_recorded_ip_geolocation
    attr_reader :delete_recorded_ip_addresses_after, :delete_recorded_browser_user_agents_after,
                :delete_recorded_ip_geolocation_after
    attr_reader :read_ip_address_from_http_request_with, :read_browser_user_agent_from_http_request_with
    attr_reader :ip_geolocation_resolver, :fail_capture_when_ip_geolocation_is_unavailable
    attr_reader :trusted_proxy_configuration_digest, :reason_for_storing_request_evidence_unencrypted

    # --- Hooks ----------------------------------------------------------------
    attr_reader :after_event_is_committed, :report_after_commit_failure_with

    def initialize
      # Identity. "User" is the overwhelmingly common case; the host overrides
      # it if their actor model is "Account", "Member", or something else.
      @actor_class_name = "User"
      @current_actor_method_name = :current_user
      @parent_controller_class_name = "::ApplicationController"
      @find_current_tenant_with = ->(_controller) { nil }

      # How an actor is referenced in evidence. A GlobalID is the default
      # because it survives the actor row being deleted: the evidence keeps a
      # stable pseudonymous reference instead of a dangling foreign key or a
      # cascade that quietly destroys the record of what someone agreed to.
      @identify_actor_with = ->(actor) { default_actor_reference(actor) }

      # Actor snapshots contain only what the host names. Clickwrap never
      # serializes a whole user into evidence: a receipt should carry the
      # fields someone reviewed and chose, not every column that happened to
      # exist on the day it was written.
      @snapshot_actor_with = ->(_actor) { {} }
      @describe_authentication_with = ->(_controller) { {} }

      # Documents and policies.
      @store_document_contents_in = :database
      @document_renderer = nil
      @document_resolver = nil
      @policy_paths = ["config/clickwrap.rb", "config/clickwrap/*.rb"]

      # A required legal statement with no translation is not presentable. Fail
      # rather than show a raw I18n key, a blank, or an unexpected language.
      @raise_on_missing_translation = true

      # Presentation manifests are short-lived by design: they bind a render to
      # a submit, and a token that stayed valid for days would weaken exactly
      # the substitution check it exists to make.
      @presentation_valid_for = 2.hours

      # Integrity. The baseline detects accidental or ordinary mutation of the
      # verified bytes. Chains, anchors, and trusted timestamps are separate,
      # explicitly enabled tiers, and each one claims only what it supplies.
      @digest_canonical_receipts_with = :sha256
      @chain_event_history_with = nil
      @anchor_event_history_with = nil
      @timestamp_receipts_with = nil
      @application_version = -> { nil }
      @template_version = -> { nil }

      # Authorization. Actors can read their own receipts; anything wider is
      # the host's decision, and unredacted request evidence needs a reason.
      @authorize_receipt_access_with = ->(_controller, _receipt) { false }
      @authorize_unredacted_request_evidence_access_with = ->(_controller, _receipt, _because) { false }

      # Request evidence. Every one of these is false, and that is the whole
      # point. Recording an IP address is a decision with consequences; the
      # library will not make it silently on a host's behalf.
      @record_ip_address_by_default = false
      @record_browser_user_agent_by_default = false
      Vocabulary::IP_GEOLOCATION_DATA_FIELDS.each do |field|
        instance_variable_set(:"@record_ip_geolocation_#{field}_by_default", false)
      end

      @reason_for_recording_ip_addresses_by_default = nil
      @reason_for_recording_browser_user_agents_by_default = nil
      @reason_for_recording_ip_geolocation_by_default = nil
      @legal_basis_reference_for_recording_ip_addresses_by_default = nil
      @legal_basis_reference_for_recording_browser_user_agents_by_default = nil
      @legal_basis_reference_for_recording_ip_geolocation_by_default = nil
      @review_default_request_evidence_configuration_on = nil

      @encrypt_recorded_ip_addresses = true
      @encrypt_recorded_browser_user_agents = true
      @encrypt_recorded_ip_geolocation = true

      # nil means "every policy that enables the field must supply its own
      # rule". There is no keep-forever default anywhere in this gem.
      @delete_recorded_ip_addresses_after = nil
      @delete_recorded_browser_user_agents_after = nil
      @delete_recorded_ip_geolocation_after = nil

      # Rails' request.remote_ip is the conventional reader. The host remains
      # responsible for configuring and testing trusted proxies correctly:
      # https://api.rubyonrails.org/classes/ActionDispatch/RemoteIp.html
      @read_ip_address_from_http_request_with = ->(http_request) { http_request.remote_ip }
      @read_browser_user_agent_from_http_request_with = ->(http_request) { http_request.user_agent }
      @trusted_proxy_configuration_digest = nil

      @ip_geolocation_resolver = nil
      @fail_capture_when_ip_geolocation_is_unavailable = false

      # Hooks. These run only after required evidence and domain state have
      # committed, and a failure here is reported but can never undo the
      # committed action.
      @after_event_is_committed = ->(_event) {}
      @report_after_commit_failure_with = ->(_error, _event) {}

      # Host-registered retention calculations, keyed by the name a retention
      # class refers to.
      @retention_time_calculators = {}
    end

    # --- Identity setters -----------------------------------------------------

    def actor_class_name=(value)
      @actor_class_name = ensure_class_name(value, "actor_class_name")
    end

    def current_actor_method_name=(value)
      @current_actor_method_name = ensure_present_symbol(value, "current_actor_method_name")
    end

    def parent_controller_class_name=(value)
      @parent_controller_class_name = ensure_class_name(value, "parent_controller_class_name")
    end

    def find_current_tenant_with=(value)
      @find_current_tenant_with = ensure_callable(value, "find_current_tenant_with")
    end

    def identify_actor_with=(value)
      @identify_actor_with = ensure_callable(value, "identify_actor_with")
    end

    def snapshot_actor_with=(value)
      @snapshot_actor_with = ensure_callable(value, "snapshot_actor_with")
    end

    def describe_authentication_with=(value)
      @describe_authentication_with = ensure_callable(value, "describe_authentication_with")
    end

    # The constantized actor class, resolved lazily on first use. Lazy on
    # purpose: the initializer that sets `config.actor_class_name = "User"` runs
    # before the User model is necessarily loaded.
    def actor_class
      name = actor_class_name
      if @actor_class.nil? || @actor_class_name_at_resolution != name
        @actor_class = name.constantize
        @actor_class_name_at_resolution = name
      end
      @actor_class
    end

    def parent_controller_class = parent_controller_class_name.constantize

    # --- Document and policy setters -----------------------------------------

    def store_document_contents_in=(value)
      normalized = value.to_s.to_sym
      unless DOCUMENT_STORES.include?(normalized)
        raise ConfigurationError,
              "store_document_contents_in must be one of #{DOCUMENT_STORES.inspect}, " \
              "got #{value.inspect}. Whichever you choose, the adapter has to return immutable " \
              "bytes plus a verifiable digest — a URL alone is never a document version."
      end

      @store_document_contents_in = normalized
    end

    # Replaces the reference Markdown renderer. A custom renderer must return
    # the exact rendered bytes it offered, because Clickwrap stores their digest
    # alongside the original source digest. That is what preserves the
    # difference between "this Markdown file existed" and "this rendered
    # representation was offered".
    def document_renderer=(value)
      @document_renderer = value.nil? ? nil : ensure_callable(value, "document_renderer")
    end

    def document_resolver=(value)
      @document_resolver = value.nil? ? nil : ensure_callable(value, "document_resolver")
    end

    def raise_on_missing_translation=(value)
      @raise_on_missing_translation = ensure_boolean(value, "raise_on_missing_translation")
    end

    def presentation_valid_for=(value)
      @presentation_valid_for = ensure_duration(value, "presentation_valid_for")
    end

    # --- Integrity setters ----------------------------------------------------

    def digest_canonical_receipts_with=(value)
      @digest_canonical_receipts_with = ensure_digest_algorithm(value, "digest_canonical_receipts_with")
    end

    def chain_event_history_with=(value)
      @chain_event_history_with =
        value.nil? ? nil : ensure_digest_algorithm(value, "chain_event_history_with")
    end

    def anchor_event_history_with=(value)
      @anchor_event_history_with = ensure_adapter(value, "anchor_event_history_with", :anchor)
    end

    def timestamp_receipts_with=(value)
      @timestamp_receipts_with = ensure_adapter(value, "timestamp_receipts_with", :timestamp)
    end

    def application_version=(value)
      @application_version = value.respond_to?(:call) ? value : -> { value }
    end

    def template_version=(value)
      @template_version = value.respond_to?(:call) ? value : -> { value }
    end

    def resolved_application_version = application_version.call
    def resolved_template_version = template_version.call

    # --- Authorization setters ------------------------------------------------

    def authorize_receipt_access_with=(value)
      @authorize_receipt_access_with = ensure_callable(value, "authorize_receipt_access_with")
    end

    def authorize_unredacted_request_evidence_access_with=(value)
      @authorize_unredacted_request_evidence_access_with =
        ensure_callable(value, "authorize_unredacted_request_evidence_access_with")
    end

    # --- Request-evidence setters --------------------------------------------

    def record_ip_address_by_default=(value)
      @record_ip_address_by_default = ensure_boolean(value, "record_ip_address_by_default")
    end

    def record_browser_user_agent_by_default=(value)
      @record_browser_user_agent_by_default = ensure_boolean(value, "record_browser_user_agent_by_default")
    end

    # One setter per IP-geolocation data field, defined rather than written out
    # nine times. Each one is a separate decision about what to keep about
    # someone's network context, so each one gets its own name in the
    # initializer, its own line in the privacy inventory, and its own entry in
    # the receipt.
    Vocabulary::IP_GEOLOCATION_DATA_FIELDS.each do |field|
      setting = :"record_ip_geolocation_#{field}_by_default"

      define_method(:"#{setting}=") do |value|
        instance_variable_set(:"@#{setting}", ensure_boolean(value, setting.to_s))
      end
    end

    def encrypt_recorded_ip_addresses=(value)
      @encrypt_recorded_ip_addresses = ensure_encryption_choice(value, "encrypt_recorded_ip_addresses")
    end

    def encrypt_recorded_browser_user_agents=(value)
      @encrypt_recorded_browser_user_agents =
        ensure_encryption_choice(value, "encrypt_recorded_browser_user_agents")
    end

    def encrypt_recorded_ip_geolocation=(value)
      @encrypt_recorded_ip_geolocation = ensure_encryption_choice(value, "encrypt_recorded_ip_geolocation")
    end

    def delete_recorded_ip_addresses_after=(value)
      @delete_recorded_ip_addresses_after =
        ensure_positive_duration_or_nil(value, "delete_recorded_ip_addresses_after")
    end

    def delete_recorded_browser_user_agents_after=(value)
      @delete_recorded_browser_user_agents_after =
        ensure_positive_duration_or_nil(value, "delete_recorded_browser_user_agents_after")
    end

    def delete_recorded_ip_geolocation_after=(value)
      @delete_recorded_ip_geolocation_after =
        ensure_positive_duration_or_nil(value, "delete_recorded_ip_geolocation_after")
    end

    def read_ip_address_from_http_request_with=(value)
      @read_ip_address_from_http_request_with =
        ensure_callable(value, "read_ip_address_from_http_request_with")
    end

    def read_browser_user_agent_from_http_request_with=(value)
      @read_browser_user_agent_from_http_request_with =
        ensure_callable(value, "read_browser_user_agent_from_http_request_with")
    end

    # A digest of the host's reviewed trusted-proxy configuration, stored beside
    # any recorded IP address. It does not make the configuration correct; it
    # records which configuration was in force when the address was observed, so
    # a later reader can tell whether the value came through a path the host had
    # actually verified.
    def trusted_proxy_configuration_digest=(value)
      @trusted_proxy_configuration_digest = value&.to_s
    end

    def ip_geolocation_resolver=(value)
      @ip_geolocation_resolver = ensure_adapter(value, "ip_geolocation_resolver", :resolve)
    end

    def fail_capture_when_ip_geolocation_is_unavailable=(value)
      @fail_capture_when_ip_geolocation_is_unavailable =
        ensure_boolean(value, "fail_capture_when_ip_geolocation_is_unavailable")
    end

    # --- Hook setters ---------------------------------------------------------

    def after_event_is_committed=(value)
      @after_event_is_committed = ensure_callable(value, "after_event_is_committed")
    end

    def report_after_commit_failure_with=(value)
      @report_after_commit_failure_with = ensure_callable(value, "report_after_commit_failure_with")
    end

    # --- Retention calculations -----------------------------------------------

    # Registers a host calculation for an event-based retention rule.
    #
    #   config.calculate_retention_time_for :regulated_evidence_retention_ends do |event|
    #     [event.recorded_at_by_server + 5.years,
    #      event.subject_liquidated_at&.+(3.years)].compact.max
    #   end
    #
    # Returning nil is a legitimate answer: it means the triggering host event
    # has not happened yet, so the record is not due for disposition and
    # Clickwrap reports it as unresolved rather than inventing a date.
    def calculate_retention_time_for(name, &block)
      raise ConfigurationError, "calculate_retention_time_for needs a block" unless block

      @retention_time_calculators[name.to_sym] = block
    end

    def retention_time_calculator_names = @retention_time_calculators.keys

    def resolve_retention_time(name, event)
      calculator = @retention_time_calculators[name.to_sym]

      unless calculator
        raise ConfigurationError,
              "No retention calculation is registered for #{name.inspect}. A retention class " \
              "asked for it with `retain_..._until #{name.inspect}`. Register it with " \
              "`config.calculate_retention_time_for #{name.inspect} do |event| ... end`."
      end

      calculator.call(event)
    end

    # --- Cross-field validation -----------------------------------------------

    # Run at the end of `Clickwrap.configure`. The per-setter checks already
    # caught the typos; these are the things that need the whole block resolved.
    def validate!
      validate_request_evidence_defaults!
      validate_ip_geolocation_resolver!
      true
    end

    # A convenience the initializer template and `clickwrap:doctor` both use.
    def records_any_request_evidence_by_default?
      record_ip_address_by_default ||
        record_browser_user_agent_by_default ||
        enabled_default_ip_geolocation_fields.any?
    end

    def enabled_default_ip_geolocation_fields
      Vocabulary::IP_GEOLOCATION_DATA_FIELDS.select do |field|
        public_send(:"record_ip_geolocation_#{field}_by_default")
      end
    end

    private

    def default_actor_reference(actor)
      return nil if actor.nil?
      return actor.clickwrap_actor_reference if actor.respond_to?(:clickwrap_actor_reference)
      return actor.to_gid.to_s if actor.respond_to?(:to_gid)

      "#{actor.class.name}/#{actor.id}"
    end

    def validate_request_evidence_defaults!
      {
        ip_address: [record_ip_address_by_default,
                     reason_for_recording_ip_addresses_by_default,
                     delete_recorded_ip_addresses_after],
        browser_user_agent: [record_browser_user_agent_by_default,
                             reason_for_recording_browser_user_agents_by_default,
                             delete_recorded_browser_user_agents_after],
        ip_geolocation: [enabled_default_ip_geolocation_fields.any?,
                         reason_for_recording_ip_geolocation_by_default,
                         delete_recorded_ip_geolocation_after]
      }.each do |category, (enabled, reason, delete_after)|
        next unless enabled

        if reason.to_s.strip.empty?
          raise ConfigurationError,
                "Clickwrap is set to record #{category} for every policy by default, but " \
                "`reason_for_recording_#{plural_for(category)}_by_default` is blank. Say in one " \
                "plain sentence why the application needs it. If only some policies need it, " \
                "turn the default off and enable it in those policies instead."
        end

        next unless delete_after.nil?

        raise ConfigurationError,
              "Clickwrap is set to record #{category} for every policy by default, but " \
              "`delete_recorded_#{plural_for(category)}_after` is nil, so nothing would ever " \
              "delete it. Set a reviewed period, or turn the default off and let each policy " \
              "choose its own retention rule."
      end
    end

    def plural_for(category)
      case category
      when :ip_address then "ip_addresses"
      when :browser_user_agent then "browser_user_agents"
      else "ip_geolocation"
      end
    end

    def validate_ip_geolocation_resolver!
      return if ip_geolocation_resolver
      return if enabled_default_ip_geolocation_fields.empty? && !fail_capture_when_ip_geolocation_is_unavailable

      if enabled_default_ip_geolocation_fields.any?
        raise ConfigurationError,
              "Clickwrap is set to record the IP-geolocation fields " \
              "#{enabled_default_ip_geolocation_fields.join(", ")} but no " \
              "`ip_geolocation_resolver` is configured, so there is nothing to resolve them. " \
              "Set one (for example Clickwrap::IpGeolocation::TrackdownResolver.new) or turn " \
              "the fields off."
      end

      raise ConfigurationError,
            "`fail_capture_when_ip_geolocation_is_unavailable` is true but no " \
            "`ip_geolocation_resolver` is configured, so every capture would fail."
    end

    # --- Setter helpers -------------------------------------------------------

    def ensure_callable(value, name)
      unless value.respond_to?(:call)
        raise ConfigurationError,
              "#{name} must respond to #call (a proc or lambda), got #{value.inspect}"
      end

      value
    end

    def ensure_adapter(value, name, required_method)
      return nil if value.nil?

      unless value.respond_to?(required_method)
        raise ConfigurationError,
              "#{name} must respond to ##{required_method}, got #{value.inspect}. See the " \
              "adapter contract in the README."
      end

      value
    end

    def ensure_class_name(value, name)
      class_name = value.is_a?(Class) ? value.name : value.to_s

      raise ConfigurationError, "#{name} can't be blank" if class_name.strip.empty?

      class_name
    end

    def ensure_present_symbol(value, name)
      symbol = value.to_s.strip

      raise ConfigurationError, "#{name} can't be blank" if symbol.empty?

      symbol.to_sym
    end

    def ensure_boolean(value, name)
      unless [true, false].include?(value)
        raise ConfigurationError, "#{name} must be true or false, got #{value.inspect}"
      end

      value
    end

    # Storing raw IP addresses or browser user-agent strings unencrypted is
    # allowed, because some hosts have a reviewed reason for it and pretending
    # otherwise would just push them to store the values somewhere worse. But it
    # is never the default, and it is never a quiet one-character change.
    def ensure_encryption_choice(value, name)
      return value if value == true

      if value == false
        return false if @deliberately_storing_request_evidence_unencrypted

        raise ConfigurationError,
              "#{name} = false stores this personal data in plain text in your database, where " \
              "it will also appear in ordinary backups and database dumps. If that is a " \
              "reviewed decision, say so explicitly first:\n\n" \
              "  config.deliberately_store_request_evidence_unencrypted!(\n" \
              "    because: \"...your reviewed reason...\"\n" \
              "  )\n"
      end

      raise ConfigurationError, "#{name} must be true or false, got #{value.inspect}"
    end

    def ensure_digest_algorithm(value, name)
      normalized = value.to_s.to_sym

      unless DIGEST_ALGORITHMS.include?(normalized)
        raise ConfigurationError,
              "#{name} must be one of #{DIGEST_ALGORITHMS.inspect}, got #{value.inspect}"
      end

      normalized
    end

    def ensure_duration(value, name)
      unless value.respond_to?(:from_now) && value.respond_to?(:ago)
        raise ConfigurationError,
              "#{name} must be a duration (like 2.hours), got #{value.inspect}"
      end

      value
    end

    def ensure_positive_duration_or_nil(value, name)
      return nil if value.nil?

      duration = ensure_duration(value, name)

      unless duration.to_i.positive?
        raise ConfigurationError,
              "#{name} must be a period in the future, got #{value.inspect}. Use nil if each " \
              "policy should choose its own retention rule."
      end

      duration
    end

    public

    # The deliberate, named escape hatch referenced by `ensure_encryption_choice`.
    # It exists so that turning encryption off is a sentence a reviewer can find
    # in a diff, with the host's own reason attached, rather than a `false`.
    def deliberately_store_request_evidence_unencrypted!(because:)
      if because.to_s.strip.empty?
        raise ConfigurationError,
              "deliberately_store_request_evidence_unencrypted! needs a `because:` explaining " \
              "the reviewed decision."
      end

      @deliberately_storing_request_evidence_unencrypted = true
      @reason_for_storing_request_evidence_unencrypted = because
    end

    def storing_request_evidence_unencrypted? = @deliberately_storing_request_evidence_unencrypted == true
  end
end
