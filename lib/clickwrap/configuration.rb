# frozen_string_literal: true

require_relative "errors"

module Clickwrap
  # The single configuration object the host populates in
  # `config/initializers/clickwrap.rb` via `Clickwrap.configure do |config| ... end`.
  #
  # Design rules:
  #   - Runtime adapters and class names are read at the point of use. Policy
  #     semantics — including merged request-evidence defaults — are copied into
  #     the immutable compiled policy revision at boot, so changing this object
  #     cannot mutate a form that was already rendered.
  #   - Class names are stored as strings and constantized lazily, so the
  #     initializer works no matter when the app loads (the User model may not
  #     exist yet at boot).
  #   - Validating setters normalize their input and raise a plain-English
  #     ConfigurationError on a bad value — failing at the assignment line
  #     rather than at 3am with a NoMethodError. `validate!` runs once more at
  #     the end of `configure` for the cross-field checks.
  #   - Every hook defaults to a no-op, so the gem works untouched and a host
  #     wires hooks only as needed.
  #   - Nothing here collects personal data by default. Every `record_*` flag
  #     starts false. Turning one on takes one line and nothing else; the
  #     purpose and the disposal answer have honest gem-supplied defaults, and
  #     a host who wants reviewed ones writes them.
  #
  # One setting deserves its own note: there is deliberately no
  # `gdpr_compliant_mode`, `maximum_evidence`, `full_evidence`, or
  # `legal_proof`. Those names hide what they collect and pretend to make a
  # legal determination, which is exactly the thing this gem exists not to do.
  # `record_request_evidence_by_default` is the opposite kind of switch: it
  # says out loud what it records (an IP address, a browser user agent, and a
  # coarse country/region/city estimate), it enables nothing finer, and it
  # claims nothing about the law.
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
    attr_reader :document_link_html_options_with
    attr_reader :hotwire_native_document_links
    attr_reader :publish_documents_after_database_preparation
    attr_accessor :policy_paths

    attr_reader :raise_on_missing_translation

    # --- Development aids -----------------------------------------------------
    attr_accessor :lint_presentations

    # --- Presentation ---------------------------------------------------------
    attr_reader :presentation_valid_for
    attr_reader :remediation_token_valid_for

    # --- Integrity ------------------------------------------------------------
    attr_reader :digest_canonical_receipts_with, :chain_event_history_with
    attr_reader :anchor_event_history_with, :timestamp_receipts_with
    attr_reader :application_version, :template_version

    # --- Authorization --------------------------------------------------------
    attr_reader :authorize_receipt_access_with, :authorize_unredacted_request_evidence_access_with
    attr_reader :verify_actor_can_act_for_represented_party_with
    attr_reader :authorize_clickwrap_remediation_subject_with
    attr_reader :authorize_clickwrap_remediation_represented_party_with

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
    attr_reader :find_request_evidence_binding_key_with

    # --- Hooks ----------------------------------------------------------------
    attr_reader :after_event_is_committed, :report_after_commit_failure_with

    def initialize
      # Identity. "User" is the overwhelmingly common case; the host overrides
      # it if their actor model is "Account", "Member", or something else.
      @actor_class_name = "User"
      @current_actor_method_name = :current_user
      @parent_controller_class_name = "ApplicationController"
      @find_current_tenant_with = ->(_controller) {}

      # How an actor is referenced in evidence. Prefer a host override, then a
      # GlobalID when available, then a stable class/id string in minimal Rails.
      # The resulting string survives row deletion instead of becoming a
      # cascading foreign-key loss.
      @identify_actor_with = ->(actor) { default_actor_reference(actor) }

      # Actor snapshots contain only what the host names. Clickwrap never
      # serializes a whole user into evidence: a receipt should carry the
      # fields someone reviewed and chose, not every column that happened to
      # exist on the day it was written.
      @snapshot_actor_with = ->(_actor) { {} }

      # An honest default: when the controller can name a current actor, the
      # request ran under an application-authenticated session; when it cannot
      # — a signup form, a public capture screen, a controller with no
      # authentication at all — nothing is claimed. The temptation this guards
      # against is describing every request as authenticated merely because it
      # passed through ApplicationController. Deliberately gentler than the
      # capture path's actor resolution: describing authentication is context,
      # not identity, so a missing actor method here means "nothing to
      # describe", never an error.
      configuration = self
      @describe_authentication_with = lambda do |controller|
        method_name = configuration.current_actor_method_name
        actor = controller.respond_to?(method_name, true) ? controller.send(method_name) : nil
        actor ? { method: :authenticated_session } : {}
      end

      # Documents and policies.
      @store_document_contents_in = :database
      @document_renderer = DocumentRenderer.new
      @document_resolver = nil
      @document_link_html_options_with = ->(_document) { { target: "_blank", rel: "noopener" } }
      @hotwire_native_document_links = nil
      @policy_paths = ["config/clickwrap.rb", "config/clickwrap/*.rb"]

      # Publishing rides `db:prepare`, so the deploy step everyone forgets
      # does not exist: by the time the server takes traffic, every declared
      # document version has an immutable snapshot. Idempotent — an
      # already-published version is left untouched — and a publish refusal
      # (a reused label over changed bytes) fails the deploy loudly, which is
      # strictly better than signups failing quietly later.
      @publish_documents_after_database_preparation = true

      # A required legal statement with no translation is not presentable. Fail
      # rather than show a raw I18n key, a blank, or an unexpected language.
      @raise_on_missing_translation = true

      # nil means "decide from the environment": on in development and test,
      # off everywhere else. `true` and `false` answer for a host that
      # disagrees with either half — a linter nobody can turn off is a warning
      # people learn to scroll past.
      @lint_presentations = nil

      # Presentation manifests are short-lived by design: they bind a render to
      # a submit, and a token that stayed valid for days would weaken exactly
      # the substitution check it exists to make.
      @presentation_valid_for = 2.hours
      @remediation_token_valid_for = 2.hours

      # Integrity. The baseline detects accidental or ordinary mutation of the
      # verified bytes. Chains, anchors, and third-party timestamps are separate,
      # explicitly enabled tiers, and each one claims only what it supplies.
      @digest_canonical_receipts_with = :sha256
      @chain_event_history_with = nil
      @anchor_event_history_with = nil
      @timestamp_receipts_with = nil
      @application_version = -> {}
      @template_version = -> {}

      # Authorization. Actors can read their own receipts; anything wider is
      # the host's decision, and unredacted request evidence needs a reason.
      @authorize_receipt_access_with = ->(_controller, _receipt) { false }
      @authorize_unredacted_request_evidence_access_with = ->(_controller, _receipt, _because) { false }
      @verify_actor_can_act_for_represented_party_with = lambda do |actor:, represented_party:, policy:,
                                                                    authentication_context:, tenant:|
        AuthorityDecision.new(authorized: false)
      end
      @authorize_clickwrap_remediation_subject_with = lambda do |actor:, subject:, policy:, controller:|
        subject.nil?
      end
      @authorize_clickwrap_remediation_represented_party_with =
        lambda do |actor:, represented_party:, policy:, controller:|
          represented_party.nil?
        end
      @remediation_subject_authorization_configured = false
      @remediation_represented_party_authorization_configured = false
      @represented_party_authority_adapters = {
        "organizations_membership" => Integrations::OrganizationsAuthority.new
      }

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
      # rule" — or, for by-default recording, that the host has said
      # `keep_recorded_..._indefinitely!(because: "…")` out loud. Keeping
      # forever is never silent: it is either the per-policy retention class's
      # explicit business, or a named, reasoned sentence in the initializer.
      @delete_recorded_ip_addresses_after = nil
      @delete_recorded_browser_user_agents_after = nil
      @delete_recorded_ip_geolocation_after = nil
      @keep_recorded_request_evidence_indefinitely = {}

      # Rails' request.remote_ip is the conventional reader. The host remains
      # responsible for configuring and testing trusted proxies correctly:
      # https://api.rubyonrails.org/classes/ActionDispatch/RemoteIp.html
      @read_ip_address_from_http_request_with = ->(http_request) { http_request.remote_ip }
      @read_browser_user_agent_from_http_request_with = ->(http_request) { http_request.user_agent }
      @trusted_proxy_configuration_digest = nil

      @ip_geolocation_resolver = nil
      @ip_geolocation_resolvers = {}
      @automatically_adopted_ip_geolocation_resolver = nil
      @considered_automatic_ip_geolocation_resolver = false
      @fail_capture_when_ip_geolocation_is_unavailable = false

      # The keyed annex digest carries a key ID so a host can rotate keys
      # without making old annexes unverifiable. The default derives one key
      # from Rails' key generator and names it by a non-secret fingerprint.
      # Production hosts with explicit key rotation can replace both settings
      # with a credentials-backed keyring.
      @current_request_evidence_binding_key_id = nil
      @find_request_evidence_binding_key_with = lambda do |requested_key_id|
        key = default_request_evidence_binding_key
        expected_id = default_request_evidence_binding_key_id(key)
        key if key && Digest.secure_compare?(requested_key_id.to_s, expected_id.to_s)
      end

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

    # Chooses how document bytes become the representation people are offered.
    # `:safe_text` (the default) escapes everything into a faithful <pre>
    # block; `:markdown` renders real HTML through whichever Markdown library
    # the application already bundles (commonmarker, redcarpet, or kramdown —
    # no new dependency); `:markdown_rails` renders through the application's
    # OWN registered markdown-rails renderer — the exact pipeline its public
    # `.md` pages already go through — so the stored snapshot is byte-identical
    # to the page readers see, by construction. A custom renderer object must
    # return the exact rendered bytes it offered, because Clickwrap stores
    # their digest alongside the original source digest. That is what preserves
    # the difference between "this Markdown file existed" and "this rendered
    # representation was offered".
    def document_renderer=(value)
      @document_renderer =
        case value
        when nil then nil
        when :markdown then DocumentRenderers::Markdown.new
        when :markdown_rails then DocumentRenderers::MarkdownRails.new
        when :safe_text then DocumentRenderer.new
        when Symbol
          raise ConfigurationError,
                "document_renderer accepts :safe_text, :markdown, :markdown_rails, or an " \
                "object responding to call(bytes, definition) — not #{value.inspect}."
        else ensure_callable(value, "document_renderer")
        end
    end

    def document_resolver=(value)
      @document_resolver = value.nil? ? nil : ensure_callable(value, "document_resolver")
    end

    # Navigation attributes only; the immutable href is signed into the
    # presentation and cannot be replaced through this styling/client hook.
    def document_link_html_options_with=(value)
      @document_link_html_options_with = ensure_callable(value, "document_link_html_options_with")
    end

    HOTWIRE_NATIVE_DOCUMENT_LINK_MODES = %i[external_browser same_screen].freeze

    # One declarative answer for how document links behave inside a Hotwire
    # Native app, doing both halves coherently — the signed href AND the
    # navigation attributes:
    #
    #   config.hotwire_native_document_links = {
    #     open_in: :external_browser,
    #     canonical_host: "https://www.example.com"
    #   }
    #
    # `:external_browser` absolutizes every document link against your
    # canonical host and opens it outside the WebView — the right answer when
    # clickwraps render on native AUTH SHEETS, where a same-host navigation
    # pops the sheet and loses the half-filled form behind it. `:same_screen`
    # leaves plain same-host links for your native path configuration to route
    # (a modal document sheet inside a signed-in funnel, for example).
    #
    # When set, this answers native renders entirely; your
    # `document_link_html_options_with` hook continues to answer everything
    # else.
    #
    # `open_in:` also takes a callable, for an app whose native screens need
    # different answers in different places — the auth sheet that must escape
    # the WebView, the signed-in funnel that routes a document sheet itself:
    #
    #   config.hotwire_native_document_links = {
    #     open_in: ->(controller) { controller.signing_up? ? :external_browser : :same_screen },
    #     canonical_host: "https://www.example.com"
    #   }
    #
    # It is asked twice per document link — once when the href is signed into
    # the presentation, once when the link's attributes are rendered — and is
    # handed the same controller both times, so it must answer from the
    # request rather than from anything that changes between those moments.
    # A callable `open_in:` needs `canonical_host:`, because nothing at boot
    # can rule out its answering `:external_browser`.
    def hotwire_native_document_links=(value)
      if value.nil?
        @hotwire_native_document_links = nil
        return
      end

      unless value.is_a?(Hash)
        raise ConfigurationError,
              "hotwire_native_document_links takes nil or a Hash like " \
              "{ open_in: :external_browser, canonical_host: \"https://www.example.com\" }."
      end

      options = value.symbolize_keys
      open_in = options[:open_in]
      unless HOTWIRE_NATIVE_DOCUMENT_LINK_MODES.include?(open_in) || open_in.respond_to?(:call)
        raise ConfigurationError,
              "hotwire_native_document_links needs `open_in:` as one of " \
              "#{HOTWIRE_NATIVE_DOCUMENT_LINK_MODES.map(&:inspect).join(" or ")}, or a callable " \
              "answering one of them per request — got #{open_in.inspect}."
      end

      unknown = options.keys - %i[open_in canonical_host]
      unless unknown.empty?
        raise ConfigurationError,
              "hotwire_native_document_links has unknown option#{"s" if unknown.many?} " \
              "#{unknown.map(&:inspect).join(", ")}. Supported options are :open_in and " \
              ":canonical_host."
      end

      canonical_host = options[:canonical_host]
      if open_in == :external_browser || open_in.respond_to?(:call)
        if canonical_host.nil?
          raise ConfigurationError,
                "hotwire_native_document_links with open_in: " \
                "#{open_in.respond_to?(:call) ? "a callable" : ":external_browser"} needs a " \
                "`canonical_host:` — the absolute https host the external browser opens, for " \
                "example \"https://www.example.com\". A relative link would land back inside " \
                "the WebView this setting exists to escape#{if open_in.respond_to?(:call)
                                                              ", and nothing at boot can rule " \
                                                                "out a callable answering :external_browser"
                                                            end}."
        end
        validate_hotwire_native_canonical_host!(canonical_host) unless canonical_host.respond_to?(:call)
      elsif canonical_host
        raise ConfigurationError,
              "hotwire_native_document_links with open_in: :same_screen keeps ordinary " \
              "same-host links, so `canonical_host:` has no meaning there. Remove it, or use " \
              "open_in: :external_browser."
      end

      @hotwire_native_document_links = { open_in: open_in, canonical_host: canonical_host }.freeze
    end

    # The mode this render should use, resolved at use time so a callable can
    # answer per request or per screen. `context` is the controller handling
    # the request; both the href and the link attributes are resolved from the
    # same one, so the two halves of a document link cannot disagree.
    def hotwire_native_document_link_mode(context = nil)
      configured = hotwire_native_document_links&.fetch(:open_in, nil)
      return configured unless configured.respond_to?(:call)

      resolved = (configured.arity.zero? ? configured.call : configured.call(context))&.to_sym

      unless HOTWIRE_NATIVE_DOCUMENT_LINK_MODES.include?(resolved)
        raise ConfigurationError,
              "hotwire_native_document_links `open_in:` answered #{resolved.inspect}. A callable " \
              "there must answer #{HOTWIRE_NATIVE_DOCUMENT_LINK_MODES.map(&:inspect).join(" or ")} " \
              "on every request — there is no third way for a document link to open."
      end

      resolved
    end

    # The canonical host, resolved and validated at use time so a host that is
    # only knowable after boot (application config, credentials) can be a
    # callable. Trailing slashes are trimmed because the engine path this
    # prefixes always begins with one.
    def hotwire_native_canonical_host
      configured = hotwire_native_document_links&.fetch(:canonical_host, nil)
      return nil if configured.nil?

      resolved = configured.respond_to?(:call) ? configured.call.to_s : configured.to_s
      validate_hotwire_native_canonical_host!(resolved)
      resolved.chomp("/")
    end

    def validate_hotwire_native_canonical_host!(value)
      return if value.to_s.start_with?("https://")

      raise ConfigurationError,
            "hotwire_native_document_links canonical_host must be an absolute https:// URL " \
            "(got #{value.inspect}). It is the address an external browser opens on a user's " \
            "phone; anything else either stays inside the WebView or downgrades the transport."
    end
    private :validate_hotwire_native_canonical_host!

    def raise_on_missing_translation=(value)
      @raise_on_missing_translation = ensure_boolean(value, "raise_on_missing_translation")
    end

    def publish_documents_after_database_preparation=(value)
      @publish_documents_after_database_preparation =
        ensure_boolean(value, "publish_documents_after_database_preparation")
    end

    def presentation_valid_for=(value)
      @presentation_valid_for = ensure_duration(value, "presentation_valid_for")
    end

    def remediation_token_valid_for=(value)
      @remediation_token_valid_for = ensure_duration(value, "remediation_token_valid_for")
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
      @anchor_event_history_with =
        ensure_adapter(value, "anchor_event_history_with", :anchor, :verify, :capabilities)
    end

    def timestamp_receipts_with=(value)
      @timestamp_receipts_with =
        ensure_adapter(value, "timestamp_receipts_with", :timestamp, :verify, :capabilities)
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

    def verify_actor_can_act_for_represented_party_with=(value)
      @verify_actor_can_act_for_represented_party_with =
        ensure_callable(value, "verify_actor_can_act_for_represented_party_with")
    end

    def authorize_clickwrap_remediation_subject_with=(value)
      @authorize_clickwrap_remediation_subject_with =
        ensure_callable(value, "authorize_clickwrap_remediation_subject_with")
      @remediation_subject_authorization_configured = true
    end

    def authorize_clickwrap_remediation_represented_party_with=(value)
      @authorize_clickwrap_remediation_represented_party_with =
        ensure_callable(value, "authorize_clickwrap_remediation_represented_party_with")
      @remediation_represented_party_authorization_configured = true
    end

    def remediation_subject_authorization_configured? = @remediation_subject_authorization_configured

    def remediation_represented_party_authorization_configured?
      @remediation_represented_party_authorization_configured
    end

    # Register a named, server-side authority adapter. Policies refer to the
    # name from their compiled revision; the browser never submits it.
    #
    #   config.register_represented_party_authority :company_directory, MyAdapter.new
    #
    # The adapter receives actor:, represented_party:, authority_rule:, tenant:,
    # and authentication_context:, and returns Clickwrap::AuthorityDecision.
    def register_represented_party_authority(name, adapter)
      key = ensure_present_symbol(name, "represented-party authority name").to_s
      if @represented_party_authority_adapters.key?(key)
        raise ConfigurationError,
              "A represented-party authority adapter named #{key.inspect} is already registered. " \
              "Use one stable name per adapter; Clickwrap will not silently replace an " \
              "authorization decision because initializer order changed."
      end

      @represented_party_authority_adapters[key] =
        ensure_adapter(adapter, "represented-party authority #{key}", :verify)
    end

    def represented_party_authority_adapter(name)
      @represented_party_authority_adapters[name.to_s]
    end

    def represented_party_authority_adapter_names
      @represented_party_authority_adapters.keys.sort.freeze
    end

    # --- Request-evidence setters --------------------------------------------

    # The one switch.
    #
    #   config.record_request_evidence_by_default = true
    #
    # Records, on every policy: the IP address the request arrived from, the
    # browser user agent it sent, and a coarse country/region/city estimate for
    # that address. Nothing finer — a postal code, coordinates, a timezone, a
    # metro code — and nothing else at all. The purpose and the disposal answer
    # have honest gem defaults (see `Vocabulary::DEFAULT_REQUEST_EVIDENCE_PURPOSE`
    # and the keep-indefinitely posture below), so this line is genuinely the
    # whole first step.
    #
    # It is a fan-out setter, not a mode: it writes the individual
    # `record_*_by_default` flags, which means it composes with them in reading
    # order. Write the switch first and a narrower flag after it to carve one
    # field back out —
    #
    #   config.record_request_evidence_by_default = true
    #   config.record_browser_user_agent_by_default = false
    #
    # — and any policy can still override all of it with `record_ip_address`,
    # `do_not_record_ip_address`, and their siblings. Setting it to false turns
    # the same three fields off and leaves the finer geolocation fields alone,
    # because it never turned those on.
    def record_request_evidence_by_default=(value)
      enabled = ensure_boolean(value, "record_request_evidence_by_default")

      @record_ip_address_by_default = enabled
      @record_browser_user_agent_by_default = enabled
      Vocabulary::COARSE_IP_GEOLOCATION_DATA_FIELDS.each do |field|
        instance_variable_set(:"@record_ip_geolocation_#{field}_by_default", enabled)
      end
    end

    # Reads back what the switch describes rather than a remembered assignment:
    # true when all three coarse fields are on, however they were turned on.
    def record_request_evidence_by_default
      record_ip_address_by_default && record_browser_user_agent_by_default &&
        Vocabulary::COARSE_IP_GEOLOCATION_DATA_FIELDS.all? do |field|
          public_send(:"record_ip_geolocation_#{field}_by_default")
        end
    end

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
      if value.nil?
        @trusted_proxy_configuration_digest = nil
        return
      end

      normalized = value.to_s.strip
      unless Digest.well_formed?(normalized)
        raise ConfigurationError,
              "trusted_proxy_configuration_digest must be a complete prefixed SHA-2 digest, " \
              "such as `sha256:` followed by 64 lowercase hexadecimal characters. It records " \
              "which reviewed proxy configuration was in force; a label or TODO is not a digest."
      end

      @trusted_proxy_configuration_digest = normalized
    end

    def ip_geolocation_resolver=(value)
      @ip_geolocation_resolver = ensure_ip_geolocation_resolver(value, "ip_geolocation_resolver")
    end

    # Register more than one resolver and let each server-owned policy select
    # one by name with `record_ip_geolocation ..., using: :maxmind`.
    def register_ip_geolocation_resolver(name, resolver)
      key = ensure_present_symbol(name, "IP-geolocation resolver name").to_s
      if key == "application_default" || @ip_geolocation_resolvers.key?(key)
        raise ConfigurationError,
              "An IP-geolocation resolver named #{key.inspect} is already reserved or registered. " \
              "Choose one stable, unique name; Clickwrap will not silently replace a resolver " \
              "because initializer order changed."
      end

      @ip_geolocation_resolvers[key] = ensure_ip_geolocation_resolver(
        resolver,
        "IP-geolocation resolver #{key}"
      )
    end

    def ip_geolocation_resolver_for(name = nil)
      return application_default_ip_geolocation_resolver if name.blank? || name.to_s == "application_default"

      @ip_geolocation_resolvers[name.to_s]
    end

    # What a policy gets when it does not name a resolver: the host's own, or —
    # when they never set one and their bundle already carries `trackdown` 0.4
    # or newer — the official adapter for it. That is the whole "trackdown plus
    # Cloudflare just works" path, and it is deliberately not a silent
    # collection decision: nothing calls this until a policy has already
    # enabled an IP-geolocation field.
    #
    # An installed-but-too-old trackdown is NOT hidden here. The adapter's own
    # sentence about upgrading is more useful than pretending the gem is
    # missing.
    def application_default_ip_geolocation_resolver
      @ip_geolocation_resolver || automatically_adopted_ip_geolocation_resolver
    end

    # The resolver actually in force, for anything that only wants to describe
    # the configuration (the privacy inventory, `clickwrap:doctor`). Unlike the
    # reader above it never adopts one as a side effect of being asked.
    def ip_geolocation_resolver_in_force
      @ip_geolocation_resolver || @automatically_adopted_ip_geolocation_resolver
    end

    def ip_geolocation_resolver_was_adopted_automatically?
      @ip_geolocation_resolver.nil? && !@automatically_adopted_ip_geolocation_resolver.nil?
    end

    def ip_geolocation_resolver_names = @ip_geolocation_resolvers.keys.sort.freeze

    # Plain-English key-rotation API. The ID is evidence and must stay stable;
    # the callback returns key bytes for current OR historical IDs.
    #
    #   config.current_request_evidence_binding_key_id = "request-evidence-2026-01"
    #   config.find_request_evidence_binding_key_with = ->(key_id) { keyring[key_id] }
    def current_request_evidence_binding_key_id=(value)
      @current_request_evidence_binding_key_id = ensure_present_string(
        value, "current_request_evidence_binding_key_id"
      )
    end

    def current_request_evidence_binding_key_id
      @current_request_evidence_binding_key_id ||
        default_request_evidence_binding_key_id(default_request_evidence_binding_key)
    end

    def find_request_evidence_binding_key_with=(value)
      @find_request_evidence_binding_key_with =
        ensure_callable(value, "find_request_evidence_binding_key_with")
    end

    def request_evidence_binding_key_for(key_id)
      key = find_request_evidence_binding_key_with.call(key_id)
      return nil if key.nil?

      bytes = key.to_s.b
      if bytes.bytesize < 32
        raise ConfigurationError,
              "find_request_evidence_binding_key_with returned only #{bytes.bytesize} bytes for " \
              "#{key_id.inspect}. Request-evidence binding keys must be at least 32 bytes."
      end

      bytes
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

      key = ensure_present_symbol(name, "retention calculation name")
      if @retention_time_calculators.key?(key)
        raise ConfigurationError,
              "A retention calculation named #{key.inspect} is already registered. Use one " \
              "stable name per calculation; Clickwrap will not silently replace a deletion " \
              "deadline because initializer order changed."
      end

      @retention_time_calculators[key] = block
    end

    # Deliberate replacement for tests, staged migrations, or a host that is
    # intentionally changing an existing calculation. The separate verb and
    # required reason keep this from becoming last-initializer-wins behavior.
    def replace_retention_time_calculation_for(name, because:, &block)
      key = ensure_present_symbol(name, "retention calculation name")
      unless @retention_time_calculators.key?(key)
        raise ConfigurationError,
              "No retention calculation named #{key.inspect} exists to replace. Register it " \
              "first with `calculate_retention_time_for`."
      end
      unless block
        raise ConfigurationError,
              "replace_retention_time_calculation_for needs a block with the new calculation."
      end
      if because.to_s.strip.empty?
        raise ConfigurationError,
              "Replacing retention calculation #{key.inspect} needs a `because:` explaining " \
              "the reviewed change."
      end

      @retention_time_calculators[key] = block
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
      return actor.to_s if actor.is_a?(String) || actor.is_a?(Symbol)
      return actor.clickwrap_actor_reference if actor.respond_to?(:clickwrap_actor_reference)

      Reference.record(actor)
    end

    # Enabling a category by default needs nothing else. A purpose the host did
    # not write falls back to Clickwrap's own stated one, and a disposal answer
    # nobody gave means the corroboration keeps pace with the evidence it
    # corroborates — which is what core evidence has done since 0.2.0.
    #
    # Two things still fail here, and both are the host contradicting
    # themselves rather than merely leaving a blank: scaffolding text standing
    # in for a purpose, and a deletion clock set alongside a declaration to
    # keep the same category forever.
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

        if ReviewedText.placeholder?(reason)
          raise ConfigurationError,
                "Clickwrap is set to record #{category} for every policy by default, but its " \
                "reason is still scaffolding text (#{reason.inspect}). Replace it with the " \
                "application's reviewed, present-tense reason, or delete the line and let " \
                "Clickwrap record its own stated purpose."
        end

        next unless delete_after.present? && keeps_recorded_request_evidence_indefinitely?(category)

        raise ConfigurationError,
              "Clickwrap is told both to delete recorded #{category} after " \
              "#{delete_after.inspect} and to keep it indefinitely. Those are opposite " \
              "decisions — keep exactly one."
      end
    end

    def plural_for(category)
      case category
      when :ip_address then "ip_addresses"
      when :browser_user_agent then "browser_user_agents"
      else "ip_geolocation"
      end
    end

    def host_reason_for_recording_by_default(category)
      public_send(:"reason_for_recording_#{plural_for(category.to_sym)}_by_default").presence
    end

    def declare_indefinite_request_evidence!(category, because)
      @keep_recorded_request_evidence_indefinitely[category] =
        because.presence || Vocabulary::DEFAULT_REASON_FOR_KEEPING_REQUEST_EVIDENCE_INDEFINITELY
    end

    def validate_ip_geolocation_resolver!
      return if enabled_default_ip_geolocation_fields.empty? && !fail_capture_when_ip_geolocation_is_unavailable
      return if application_default_ip_geolocation_resolver

      if enabled_default_ip_geolocation_fields.any?
        raise ConfigurationError,
              "Clickwrap is set to record the IP-geolocation fields " \
              "#{enabled_default_ip_geolocation_fields.join(", ")} but no " \
              "`ip_geolocation_resolver` is configured and the `trackdown` gem is not " \
              "installed, so there is nothing to resolve them. Run " \
              "`bundle add trackdown --version \">= 0.4\"` and Clickwrap will use it, set " \
              "`config.ip_geolocation_resolver` to your own adapter, or turn the fields off."
      end

      raise ConfigurationError,
            "`fail_capture_when_ip_geolocation_is_unavailable` is true but no " \
            "`ip_geolocation_resolver` is configured, so every capture would fail."
    end

    # Considered once, at the first moment something actually needs geolocation
    # resolved, and remembered either way — including the "no trackdown here"
    # answer, so a host without it does not pay for a failed `require` on every
    # policy compile.
    def automatically_adopted_ip_geolocation_resolver
      return @automatically_adopted_ip_geolocation_resolver if @considered_automatic_ip_geolocation_resolver

      # Remembered only once the adapter has actually been built. An installed
      # trackdown too old to use raises out of here, and a host who fixes their
      # bundle and asks again must not be told the gem is missing because a
      # failed attempt got memoized as "no".
      resolver = (IpGeolocation::TrackdownResolver.new if IpGeolocation::TrackdownResolver.installed?)
      @considered_automatic_ip_geolocation_resolver = true
      @automatically_adopted_ip_geolocation_resolver = resolver
    end

    # --- Setter helpers -------------------------------------------------------

    def ensure_callable(value, name)
      unless value.respond_to?(:call)
        raise ConfigurationError,
              "#{name} must respond to #call (a proc or lambda), got #{value.inspect}"
      end

      value
    end

    def ensure_adapter(value, name, *required_methods)
      return nil if value.nil?

      missing = required_methods.reject { |required_method| value.respond_to?(required_method) }
      unless missing.empty?
        raise ConfigurationError,
              "#{name} must respond to #{missing.map { |method| "##{method}" }.join(", ")}, " \
              "but #{value.inspect} does not. See the matching adapter section in README.md."
      end

      value
    end

    def ensure_ip_geolocation_resolver(value, name)
      adapter = ensure_adapter(value, name, :resolve, :capabilities)
      return nil if adapter.nil?

      parameters = adapter.method(:resolve).parameters
      accepts_http_request = parameters.any? do |kind, parameter_name|
        kind == :keyrest || (%i[key keyreq].include?(kind) && parameter_name == :http_request)
      end
      return adapter if accepts_http_request

      raise ConfigurationError,
            "#{name} must implement `#resolve(ip_address, http_request: nil)`. The request is " \
            "explicit because request-backed providers such as Cloudflare need it to read " \
            "their location headers and record whether the host verified that CDN path. " \
            "Update #{adapter.class} to accept the `http_request:` keyword, even if that " \
            "resolver does not use it."
    rescue NameError
      raise ConfigurationError,
            "#{name} exposes #resolve but Clickwrap could not inspect its parameters. Define " \
            "`#resolve(ip_address, http_request: nil)` explicitly so request provenance is " \
            "never dropped by an opaque adapter."
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

    def ensure_present_string(value, name)
      string = value.to_s.strip
      raise ConfigurationError, "#{name} can't be blank" if string.empty?

      string
    end

    def default_request_evidence_binding_key
      if defined?(::Rails) && ::Rails.application&.key_generator
        ::Rails.application.key_generator.generate_key("clickwrap/request-evidence-binding", 32)
      else
        ENV.fetch("CLICKWRAP_REQUEST_EVIDENCE_BINDING_KEY", nil)
      end
    end

    def default_request_evidence_binding_key_id(key)
      return nil if key.nil?

      "rails_key_generator_#{Digest.hex(key)[0, 16]}"
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
              "reviewed decision, say so explicitly first:\n\n  " \
              "config.deliberately_store_request_evidence_unencrypted!(\n    " \
              "because: \"...your reviewed reason...\"\n  " \
              ")\n"
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

    # Says out loud what an absent deletion clock already means: this category
    # keeps pace with the evidence it corroborates. Request evidence exists to
    # corroborate evidence that (since 0.2.0) keeps indefinitely by default,
    # and a corroboration that expires before the thing it corroborates is a
    # scheduled weakening of the record.
    #
    # Saying it explicitly is worth doing — it puts the decision and its reason
    # in the initializer where a reviewer finds them — but since 0.3.0 it is no
    # longer the price of admission, and `because:` is optional. What a host
    # writes is kept as their own words; what they leave out gets Clickwrap's.
    def keep_recorded_ip_addresses_indefinitely!(because: nil)
      declare_indefinite_request_evidence!(:ip_address, because)
    end

    def keep_recorded_browser_user_agents_indefinitely!(because: nil)
      declare_indefinite_request_evidence!(:browser_user_agent, because)
    end

    def keep_recorded_ip_geolocation_indefinitely!(because: nil)
      declare_indefinite_request_evidence!(:ip_geolocation, because)
    end

    def keeps_recorded_request_evidence_indefinitely?(category)
      @keep_recorded_request_evidence_indefinitely.key?(category.to_sym)
    end

    # The purpose that will actually be recorded for a category enabled
    # application-wide, and which of the two wrote it. The inventory reports
    # both, so a reviewer can tell a sentence their team signed off on from the
    # one the gem supplied.
    def reason_for_recording_by_default(category)
      host_reason_for_recording_by_default(category) || Vocabulary::DEFAULT_REQUEST_EVIDENCE_PURPOSE
    end

    def reason_for_recording_by_default_source(category)
      host_reason_for_recording_by_default(category) ? "host" : "gem_default"
    end

    def reason_for_keeping_recorded_request_evidence_indefinitely(category)
      @keep_recorded_request_evidence_indefinitely[category.to_sym]
    end

    # The named escape hatch for turning encryption off. The ceremony is the
    # method: you cannot reach `encrypt_recorded_* = false` without writing a
    # line that says out loud what you are doing, and that line is what a
    # reviewer finds in a diff. Since 0.3.0 the `because:` is optional — the
    # gem records its own sentence when you do not write one — because the
    # host's privacy policy owns the why, and demanding it twice never stopped
    # anybody who had already typed this method name.
    #
    # Encryption itself is unchanged: on by default, for all three categories.
    def deliberately_store_request_evidence_unencrypted!(because: nil)
      @deliberately_storing_request_evidence_unencrypted = true
      @reason_for_storing_request_evidence_unencrypted =
        because.presence || Vocabulary::DEFAULT_REASON_FOR_STORING_REQUEST_EVIDENCE_UNENCRYPTED
    end

    def storing_request_evidence_unencrypted? = @deliberately_storing_request_evidence_unencrypted == true

    def method_missing(name, *arguments, **options, &)
      if name.to_s.end_with?("=")
        setting = name.to_s.delete_suffix("=")
        raise ConfigurationError,
              "Clickwrap has no initializer setting named `config.#{setting}`. Check the " \
              "spelling; unknown settings are refused so a typo can never look configured."
      end

      super
    end

    def respond_to_missing?(name, include_private = false)
      super
    end
  end
end
