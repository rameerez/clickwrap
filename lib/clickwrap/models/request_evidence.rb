# frozen_string_literal: true

module Clickwrap
  # The optional request-evidence annex: IP address, browser user-agent, and
  # provider-estimated IP geolocation.
  #
  # None of it is recorded unless a policy names the field. It lives in its own
  # table, apart from the core event payload, for one specific reason: personal
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

    IP_GEOLOCATION_VALUE_COLUMNS = %w[
      ip_geolocation_country_code
      ip_geolocation_country_name
      ip_geolocation_region_name
      ip_geolocation_region_code
      ip_geolocation_city_name
      ip_geolocation_postal_code
      ip_geolocation_latitude
      ip_geolocation_longitude
      ip_geolocation_timezone
      ip_geolocation_continent_code
      ip_geolocation_metro_code
      ip_geolocation_accuracy_radius_in_kilometers
    ].freeze

    VALUE_COLUMNS_BY_CATEGORY = {
      ip_address: %w[ip_address_ciphertext].freeze,
      browser_user_agent: %w[browser_user_agent_ciphertext].freeze,
      ip_geolocation: IP_GEOLOCATION_VALUE_COLUMNS
    }.freeze

    # Every category gets its own HMAC. A single whole-annex HMAC cannot be
    # recomputed after one category is lawfully deleted; treating that expected
    # mismatch as acceptable would also stop us detecting a later edit to a
    # category that was *not* deleted. Independent bindings let one category be
    # disposed of while every retained category keeps verifying.
    COMMON_BINDING_COLUMNS = %w[event_id authorized_fields created_at].freeze
    BINDING_COLUMNS_BY_CATEGORY = {
      ip_address: %w[
        ip_address_ciphertext ip_address_reader_name trusted_proxy_configuration_digest
        ip_address_recorded_at ip_address_delete_after ip_address_retain_until_rule
        ip_address_deleted_at ip_address_unavailable_reason
      ],
      browser_user_agent: %w[
        browser_user_agent_ciphertext browser_user_agent_was_client_supplied
        browser_user_agent_recorded_at browser_user_agent_delete_after
        browser_user_agent_retain_until_rule browser_user_agent_deleted_at
        browser_user_agent_unavailable_reason
      ],
      ip_geolocation: %w[
        ip_geolocation_country_code ip_geolocation_country_name
        ip_geolocation_region_name ip_geolocation_region_code ip_geolocation_city_name
        ip_geolocation_postal_code ip_geolocation_latitude ip_geolocation_longitude
        ip_geolocation_timezone ip_geolocation_continent_code ip_geolocation_metro_code
        ip_geolocation_provider_name ip_geolocation_provider_source
        ip_geolocation_database_version ip_geolocation_database_sha256
        ip_geolocation_accuracy_radius_in_kilometers
        ip_geolocation_accuracy_radius_confidence_percentage ip_geolocation_was_estimated
        ip_geolocation_source_was_verified_by_host ip_geolocation_resolved_at
        ip_geolocation_unavailable_reason ip_geolocation_recorded_at
        ip_geolocation_delete_after ip_geolocation_retain_until_rule
        ip_geolocation_deleted_at
      ]
    }.transform_values(&:freeze).freeze
    BINDING_COLUMNS = (COMMON_BINDING_COLUMNS + BINDING_COLUMNS_BY_CATEGORY.values.flatten).uniq.freeze

    belongs_to :event, class_name: "Clickwrap::Event", inverse_of: :request_evidence

    validates :event_id, presence: true, uniqueness: true

    before_save :ensure_encryption_is_possible
    before_update :refuse_ordinary_update
    before_destroy :refuse_destroy, prepend: true

    # Application-layer encryption, on by default.
    #
    # Applied from the engine's `to_prepare` rather than declared here, because
    # whether to encrypt is a host decision (`encrypt_recorded_ip_addresses` and
    # friends) and a declaration in the class body would apply before the
    # initializer has been read. The two raw columns are named `_ciphertext` so
    # that a developer reading the schema, a database dump, or a query result
    # can tell at a glance that the plain value is not supposed to be there.
    #
    # The geolocation VALUE columns are encrypted too, when the host asks for
    # it. The provenance columns beside them — provider name, database version,
    # accuracy radius, resolution time — are not: they say how certain the
    # values are rather than what they are, they are what `clickwrap:doctor` and
    # the privacy inventory read, and encrypting them would hide the uncertainty
    # while leaving the estimate itself just as sensitive.
    #
    # A country code is lower precision than a coordinate, but it is still
    # personal data once it is attached to an identified actor and an event, so
    # it is in this list rather than treated as harmless.
    ENCRYPTED_COLUMNS = {
      ip_address_ciphertext: :encrypt_recorded_ip_addresses,
      browser_user_agent_ciphertext: :encrypt_recorded_browser_user_agents,
      ip_geolocation_country_code: :encrypt_recorded_ip_geolocation,
      ip_geolocation_country_name: :encrypt_recorded_ip_geolocation,
      ip_geolocation_region_name: :encrypt_recorded_ip_geolocation,
      ip_geolocation_region_code: :encrypt_recorded_ip_geolocation,
      ip_geolocation_city_name: :encrypt_recorded_ip_geolocation,
      ip_geolocation_postal_code: :encrypt_recorded_ip_geolocation,
      ip_geolocation_latitude: :encrypt_recorded_ip_geolocation,
      ip_geolocation_longitude: :encrypt_recorded_ip_geolocation,
      ip_geolocation_timezone: :encrypt_recorded_ip_geolocation,
      ip_geolocation_continent_code: :encrypt_recorded_ip_geolocation,
      ip_geolocation_metro_code: :encrypt_recorded_ip_geolocation
    }.freeze

    # Declaring an encrypted attribute reads the column, so this can only run
    # where the table exists. On an installation that records no request
    # evidence the annex table is not created at all — and there is nothing to
    # encrypt, because there is nothing to store. It is applied again at the
    # moment an annex is actually built, so an application whose connection was
    # not up at boot still encrypts everything it was told to.
    def self.apply_configured_encryption!
      return unless respond_to?(:encrypts)
      return unless annex_table_exists?

      wanted = ENCRYPTED_COLUMNS.select { |_, setting| Clickwrap.config.public_send(setting) }.keys
      return if wanted.empty?

      already = (encrypted_attributes || []).map(&:to_sym)
      (wanted - already).each { |column| encrypts column }
    end

    def self.annex_table_exists?
      connection.data_source_exists?(table_name)
    rescue StandardError
      false
    end

    # Whether this application has Active Record encryption keys at all.
    # Reading the key raises when it is unset, which is why this is a probe
    # rather than a plain read.
    def self.encryption_keys_available?
      encryption = ::ActiveRecord::Encryption.config
      encryption.primary_key.present? && encryption.key_derivation_salt.present?
    rescue StandardError
      false
    end

    # Checked when something is actually about to be encrypted, NOT at boot.
    #
    # That distinction matters more than it looks. Adding this gem to an
    # application must never stop it from booting, and most applications
    # record no request evidence at all — so a boot-time key check would fail
    # installations that were never going to encrypt anything, before the
    # developer had a chance to run the installer or generate a key. A host
    # that does collect this data gets the sentence below the first time it
    # tries, and `clickwrap:doctor` reports the missing keys before that.
    def ensure_encryption_is_possible
      encrypted = self.class.encrypted_attributes.to_a.map(&:to_sym)
      return if encrypted.none? { |column| self[column].present? }
      return if self.class.encryption_keys_available?

      raise ConfigurationError,
            "Clickwrap is about to record request evidence it is configured to encrypt, but " \
            "this application has no Active Record encryption keys. Generate them with " \
            "`bin/rails db:encryption:init` and add them to your credentials — or, if storing " \
            "these values in plain text is a reviewed decision, say so explicitly with " \
            "`config.deliberately_store_request_evidence_unencrypted!(because: \"...\")` and " \
            "set the matching `encrypt_recorded_*` settings to false."
    end

    scope :with_ip_address_due, lambda { |at = Clickwrap.now|
      where(ip_address_deleted_at: nil).where.not(ip_address_delete_after: nil)
                                       .where(ip_address_delete_after: ..at)
    }

    scope :with_browser_user_agent_due, lambda { |at = Clickwrap.now|
      where(browser_user_agent_deleted_at: nil).where.not(browser_user_agent_delete_after: nil)
                                               .where(browser_user_agent_delete_after: ..at)
    }

    scope :with_ip_geolocation_due, lambda { |at = Clickwrap.now|
      where(ip_geolocation_deleted_at: nil).where.not(ip_geolocation_delete_after: nil)
                                           .where(ip_geolocation_delete_after: ..at)
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
    def category_binding_digests
      CATEGORIES.to_h { |category| [category.to_s, binding_digest_for(category)] }
    end

    def binding_digest_for(category)
      key_id = binding_key_id
      Digest.keyed_digest(
        CanonicalJson.generate(binding_body_for(category)),
        key: binding_key_for!(key_id),
        algorithm: Clickwrap.config.digest_canonical_receipts_with.to_s
      )
    end

    def binding_digest_algorithm = "hmac-#{Clickwrap.config.digest_canonical_receipts_with}"

    def binding_key_id
      Clickwrap.config.current_request_evidence_binding_key_id.presence ||
        raise(ConfigurationError,
              "Clickwrap cannot name the request-evidence binding key. Configure " \
              "`current_request_evidence_binding_key_id` and " \
              "`find_request_evidence_binding_key_with` before recording request evidence.")
    end

    def category_binding_digest_verified?(category:, digest:, algorithm:, key_id:)
      digest_algorithm = algorithm.to_s.delete_prefix("hmac-")
      return false unless Digest.supported?(digest_algorithm)

      key = Clickwrap.config.request_evidence_binding_key_for(key_id)
      return false if key.nil?

      # A stored value that can no longer be canonicalized cannot reproduce its
      # binding, and saying so is the honest answer — an integrity check that
      # raises tells an operator nothing except that the tool broke.
      begin
        computed = Digest.keyed_digest(
          CanonicalJson.generate(binding_body_for(category)),
          key: key,
          algorithm: digest_algorithm
        )
      rescue CanonicalJson::SerializationError
        return false
      end
      Digest.secure_compare?(computed, digest)
    end

    def binding_key_available?(key_id)
      Clickwrap.config.request_evidence_binding_key_for(key_id).present?
    end

    def any_category_disposed?
      CATEGORIES.any? { |category| deleted_for?(category) }
    end

    # The only supported mutation. The caller has already locked the root event
    # and rechecked legal holds; this method limits the write to the one named
    # category's value columns plus its deletion timestamp.
    def dispose_category!(category, at: Clickwrap.now)
      normalized = category.to_s.to_sym
      columns = VALUE_COLUMNS_BY_CATEGORY.fetch(normalized) do
        raise ArgumentError, "Unknown request-evidence category #{category.inspect}"
      end

      update_columns(columns.to_h { |column| [column, nil] }
                             .merge("#{normalized}_deleted_at" => at))
    end

    def to_s = "request evidence for event #{event_id}"

    private

    def binding_body_for(category)
      normalized = category.to_s.to_sym
      columns = COMMON_BINDING_COLUMNS + BINDING_COLUMNS_BY_CATEGORY.fetch(normalized) do
        raise ArgumentError, "Unknown request-evidence category #{category.inspect}"
      end

      columns.to_h do |column|
        [column, canonical_binding_value(public_send(column))]
      end
    end

    def canonical_binding_value(value)
      case value
      when Time, ActiveSupport::TimeWithZone then Receipt.format_time(value)
      when Hash then value.deep_stringify_keys
      else value
      end
    end

    def binding_key_for!(key_id)
      Clickwrap.config.request_evidence_binding_key_for(key_id) ||
        raise(ConfigurationError,
              "find_request_evidence_binding_key_with returned no key for the current " \
              "request-evidence binding key ID #{key_id.inspect}.")
    end

    def refuse_ordinary_update
      raise ImmutableEvidenceError,
            "Request evidence is immutable after capture. Delete one category only through " \
            "Clickwrap.delete_recorded_ip_address!, " \
            "Clickwrap.delete_recorded_browser_user_agent!, or " \
            "Clickwrap.delete_recorded_ip_geolocation!, which records the disposition."
    end

    def refuse_destroy
      raise ImmutableEvidenceError,
            "A request-evidence annex cannot be destroyed directly. Dispose each authorized " \
            "category through Clickwrap's named retention methods so the deletion is recorded."
    end
  end
end
