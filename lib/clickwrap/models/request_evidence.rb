# frozen_string_literal: true

module Clickwrap
  # The optional request-evidence annex: IP address, browser user-agent, and
  # provider-estimated IP geolocation.
  #
  # None of it is recorded unless a policy names the field. It lives in its own
  # table, apart from the immutable event, for one specific reason: personal
  # request evidence needs its own deletion schedule, and welding it into the
  # event would force a choice between ignoring a lawful deletion request and
  # destroying the historical record of an agreement. Here the annex can go away
  # on its own clock while the agreement it accompanied stays intact and
  # verifiable, and the deletion is itself recorded.
  #
  # What is stored here is bounded by what it can honestly support:
  #
  #   * an IP address is a network observation, not a person;
  #   * IP geolocation is a provider's estimate about that address, not a
  #     physical location, not GPS, and not proof anyone was there;
  #   * the User-Agent header is whatever the client chose to send.
  #
  # Every stored geolocation value therefore carries its provenance in the same
  # row. Coordinates without an accuracy radius, or a country without knowing
  # which provider guessed it, read as far more certain than they are.
  class RequestEvidence < ApplicationRecord
    self.table_name = "clickwrap_request_evidence"
    self.record_timestamps = false

    CATEGORIES = %i[ip_address browser_user_agent ip_geolocation].freeze

    belongs_to :event, class_name: "Clickwrap::Event", inverse_of: :request_evidence

    validates :event_id, presence: true, uniqueness: true

    # Application-layer encryption for the two raw values, on by default.
    #
    # Applied from the engine's `to_prepare` rather than declared here, because
    # whether to encrypt is a host decision (`encrypt_recorded_ip_addresses`) and
    # a declaration in the class body would apply before the initializer has
    # been read. The columns are named `_ciphertext` so that a developer reading
    # the schema, a database dump, or a query result can tell at a glance that
    # the plain value is not supposed to be there.
    ENCRYPTED_COLUMNS = {
      ip_address_ciphertext: :encrypt_recorded_ip_addresses,
      browser_user_agent_ciphertext: :encrypt_recorded_browser_user_agents
    }.freeze

    def self.apply_configured_encryption!
      return unless respond_to?(:encrypts)

      wanted = ENCRYPTED_COLUMNS.select { |_, setting| Clickwrap.config.public_send(setting) }.keys
      return if wanted.empty?

      ensure_encryption_keys_available!(wanted)

      already = encrypted_attributes || []
      (wanted - already.map(&:to_sym)).each { |column| encrypts column }
    end

    # Fails at boot with a sentence rather than at 3am with a stack trace from
    # inside Active Record. A host that has asked Clickwrap to encrypt this data
    # and has no keys to encrypt it with should find that out before the first
    # capture, not during one.
    def self.ensure_encryption_keys_available!(columns)
      encryption = ::ActiveRecord::Encryption.config
      return if encryption.primary_key.present? && encryption.key_derivation_salt.present?

      raise ConfigurationError,
            "Clickwrap is configured to encrypt #{columns.join(" and ")}, but this application " \
            "has no Active Record encryption keys. Generate them with " \
            "`bin/rails db:encryption:init` and add them to your credentials, or — if storing " \
            "these values in plain text is a reviewed decision — say so explicitly with " \
            "`config.deliberately_store_request_evidence_unencrypted!(because: \"...\")` and set " \
            "the matching `encrypt_recorded_*` settings to false."
    end

    scope :with_ip_address_due, lambda { |at = Clickwrap.now|
      where(ip_address_deleted_at: nil).where.not(ip_address_delete_after: nil)
                                       .where(ip_address_delete_after: ...at)
    }

    scope :with_browser_user_agent_due, lambda { |at = Clickwrap.now|
      where(browser_user_agent_deleted_at: nil).where.not(browser_user_agent_delete_after: nil)
                                               .where(browser_user_agent_delete_after: ...at)
    }

    scope :with_ip_geolocation_due, lambda { |at = Clickwrap.now|
      where(ip_geolocation_deleted_at: nil).where.not(ip_geolocation_delete_after: nil)
                                           .where(ip_geolocation_delete_after: ...at)
    }

    # --- What was actually recorded ------------------------------------------

    def recorded_ip_address? = ip_address_recorded_at.present? && ip_address_deleted_at.nil?
    def recorded_browser_user_agent? = browser_user_agent_recorded_at.present? && browser_user_agent_deleted_at.nil?
    def recorded_ip_geolocation? = ip_geolocation_recorded_at.present? && ip_geolocation_deleted_at.nil?

    def ip_address_was_deleted? = ip_address_deleted_at.present?
    def browser_user_agent_was_deleted? = browser_user_agent_deleted_at.present?
    def ip_geolocation_was_deleted? = ip_geolocation_deleted_at.present?

    def ip_geolocation_was_estimated? = ip_geolocation_was_estimated
    def ip_geolocation_source_was_verified_by_host? = ip_geolocation_source_was_verified_by_host
    def browser_user_agent_was_client_supplied? = browser_user_agent_was_client_supplied

    Vocabulary::IP_GEOLOCATION_DATA_FIELDS.each do |field|
      define_method(:"recorded_ip_geolocation_#{field}?") do
        return false unless recorded_ip_geolocation?

        authorized_ip_geolocation_fields.include?(field)
      end
    end

    def ip_address = ip_address_ciphertext
    def browser_user_agent = browser_user_agent_ciphertext

    def authorized_ip_geolocation_fields
      Array(authorized_fields.to_h["ip_geolocation"]&.select { |_, on| on }&.keys)
    end

    # --- The state a receipt reports -----------------------------------------

    # Five distinct answers, kept distinct on purpose. "Blank" is never allowed
    # to blur "we chose not to collect this" into "collection failed" into "we
    # deleted it under a retention rule" — those tell an auditor completely
    # different things about how the application behaves.
    def state_for(category, authorized_to_read: false, held: false)
      configured = authorized_for?(category)
      return "not_configured" unless configured

      return "deleted_after_retention" if deleted_for?(category)
      return "held" if held && !authorized_to_read
      return "unavailable" if unavailable_reason_for(category).present?
      return "redacted_for_this_viewer" unless authorized_to_read

      "recorded"
    end

    def unavailable_reason_for(category)
      public_send(:"#{category}_unavailable_reason")
    end

    def deleted_for?(category)
      public_send(:"#{category}_deleted_at").present?
    end

    def authorized_for?(category)
      case category.to_sym
      when :ip_address then authorized_fields.to_h["ip_address"] == true
      when :browser_user_agent then authorized_fields.to_h["browser_user_agent"] == true
      when :ip_geolocation then authorized_ip_geolocation_fields.any?
      else false
      end
    end

    # --- Binding the annex to its event --------------------------------------

    # The event keeps a digest of this annex so the two are provably the same
    # pair. It is a keyed construction, not a plain hash: an IPv4 address is 32
    # bits, so an unsalted hash of one can be tested by enumerating every
    # address in minutes, and calling that anonymization would be wrong.
    #
    # Even keyed, the result is described as a retained linkable digest. It is
    # not automatically anonymous, and a host's privacy analysis should treat it
    # as pseudonymous data that outlives the value it covers.
    def binding_digest
      Digest.keyed_digest(
        CanonicalJson.generate(binding_body),
        key: binding_key,
        algorithm: Clickwrap.config.digest_canonical_receipts_with.to_s
      )
    end

    def binding_digest_algorithm = "hmac-#{Clickwrap.config.digest_canonical_receipts_with}"

    def binding_key_id
      key = binding_key
      key ? Digest.hex(key)[0, 16] : nil
    end

    def to_s = "request evidence for event #{event_id}"

    private

    def binding_body
      {
        "event_id" => event_id,
        "authorized_fields" => authorized_fields.to_h,
        "ip_address" => ip_address_ciphertext.presence,
        "browser_user_agent" => browser_user_agent_ciphertext.presence,
        "ip_geolocation" => ip_geolocation_body.presence
      }.compact
    end

    def ip_geolocation_body
      {
        "country_code" => ip_geolocation_country_code,
        "region_code" => ip_geolocation_region_code,
        "city_name" => ip_geolocation_city_name,
        "postal_code" => ip_geolocation_postal_code,
        "latitude" => ip_geolocation_latitude&.to_s,
        "longitude" => ip_geolocation_longitude&.to_s,
        "timezone" => ip_geolocation_timezone,
        "continent_code" => ip_geolocation_continent_code,
        "metro_code" => ip_geolocation_metro_code,
        "provider_name" => ip_geolocation_provider_name,
        "provider_source" => ip_geolocation_provider_source,
        "database_version" => ip_geolocation_database_version,
        "accuracy_radius_in_kilometers" => ip_geolocation_accuracy_radius_in_kilometers
      }.compact
    end

    def binding_key
      if defined?(::Rails) && ::Rails.application&.key_generator
        ::Rails.application.key_generator.generate_key("clickwrap/request-evidence-binding", 32)
      else
        ENV.fetch("CLICKWRAP_REQUEST_EVIDENCE_BINDING_KEY", nil)
      end
    end
  end
end
