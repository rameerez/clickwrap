# frozen_string_literal: true

module Clickwrap
  # Resolves the optional request evidence for one capture: the IP address the
  # server observed, the browser user-agent the client supplied, and whatever a
  # resolver was authorized to estimate from that address.
  #
  # Four properties of this class are load-bearing.
  #
  # It runs SYNCHRONOUSLY, before the evidence and domain transaction opens. Not
  # in a job, not after commit, not in a rescue that fills the gap in later.
  # Evidence that arrives after the action it was supposed to accompany is a
  # different claim from evidence that accompanied it, and a receipt cannot tell
  # the two apart once they are in the same columns. Resolving before the
  # transaction opens also keeps a provider lookup from holding locks on
  # evidence rows while it waits on somebody else's network.
  #
  # It WRITES NOTHING. It returns a value object holding the attribute hash for
  # one `clickwrap_request_evidence` row, and the caller writes that row inside
  # the transaction that carries the protected action. Required evidence and the
  # action commit together or not at all.
  #
  # It reads ONLY from the HTTP request, through the host's configured readers.
  # No parameter, no hidden form field, and no client-supplied header can select
  # a policy, a resolver, a field, a precision, or a retention rule. A browser
  # may answer a policy; it may never author one.
  #
  # It RECORDS WHAT IT COULD NOT GET. Missing, refused, failed, and answered are
  # four different states, and every one of them ends up in a column with a
  # reason attached. Nothing here silently substitutes a blank, a zero, or the
  # word "Unknown" for an answer nobody gave.
  #
  # Nothing is collected unless the COMPILED policy says so by name. Application
  # defaults are merged into that policy at boot, not here at capture time, so a
  # configuration change necessarily produces a different policy revision and a
  # policy can explicitly narrow an application default.
  class RequestEvidenceExtractor
    # What one extraction produced.
    #
    # `attributes` is the exact attribute hash for a `clickwrap_request_evidence`
    # row, minus `event_id` and `created_at`, which the writer supplies once the
    # event has an identifier. `authorized_fields` is the same manifest that
    # travels in the row: the list of what the server-owned policy ALLOWED,
    # which is a different and more useful fact than what happens to be present.
    # A country column that is blank because the policy never authorized a
    # country reads nothing like one that is blank because a provider had no
    # answer, and the manifest is what keeps them apart.
    Resolved = Data.define(:attributes, :authorized_fields, :records_anything) do
      def initialize(attributes: {}, authorized_fields: {}, records_anything: false)
        super
      end

      def records_anything? = records_anything == true

      # This policy records nothing about the request. No row is written at all
      # — an empty annex row would be indistinguishable from one whose fields
      # were later deleted under a retention rule.
      def self.none(authorized_fields:)
        new(attributes: {}, authorized_fields: authorized_fields, records_anything: false)
      end
    end

    # Reason strings are permanent evidence vocabulary. They are added to, never
    # renamed or repurposed: a receipt written today is read by code that may be
    # years newer, and a reason that changed meaning underneath it would make
    # old evidence say something it never said.
    NO_HTTP_REQUEST = "no_http_request"
    CHANNEL_CARRIES_NO_HTTP_REQUEST = "capture_channel_carries_no_http_request"
    NO_IP_ADDRESS_ON_HTTP_REQUEST = "no_ip_address_on_http_request"
    FORWARDED_CHAIN_REFUSED = "ip_address_reader_returned_a_forwarded_chain"
    NO_BROWSER_USER_AGENT_ON_HTTP_REQUEST = "no_browser_user_agent_on_http_request"
    RESOLVER_RETURNED_NO_RESULT = "resolver_returned_no_result"
    RESOLVER_CANNOT_SUPPLY_AUTHORIZED_FIELDS = "resolver_cannot_supply_authorized_fields"
    PROVIDER_SUPPLIED_NO_AUTHORIZED_FIELD = "provider_supplied_no_authorized_field"

    # What produced the stored address. Rails' `request.remote_ip` is the
    # conventional reader and the one Clickwrap ships with; anything else is the
    # host's own, and the receipt says so rather than implying Rails' spoof
    # checks and trusted-proxy handling were involved when they were not.
    RAILS_REQUEST_REMOTE_IP_READER_NAME = "rails_request_remote_ip"
    HOST_CONFIGURED_READER_NAME = "host_configured_reader"

    # Channels that structurally carry no HTTP request. A background job has no
    # browser and never had one; that is a fact about the capture, not a failure
    # to collect something, and the reason string says which it was.
    CHANNELS_WITHOUT_AN_HTTP_REQUEST = %w[background_job imported_provider system].freeze

    # Reasons are stored in a string column. A pathological error class name
    # must not turn a recorded unavailability into a failed INSERT that rolls
    # back the protected action.
    MAXIMUM_UNAVAILABLE_REASON_LENGTH = 200

    # Exactly which columns each authorized field unlocks. This table IS the
    # minimization guarantee, which is why it is a table rather than a run of
    # conditionals: a reviewer can see at a glance that authorizing `country`
    # unlocks a country code and name and nothing else, and adding a column here
    # is a visible decision to store more. Coordinates are absent on purpose —
    # they are a coupled pair and are handled separately below.
    TEXT_COLUMNS_BY_AUTHORIZED_FIELD = {
      "country" => { ip_geolocation_country_code: :country_code,
                     ip_geolocation_country_name: :country_name },
      "region" => { ip_geolocation_region_name: :region_name,
                    ip_geolocation_region_code: :region_code },
      "city" => { ip_geolocation_city_name: :city_name },
      "postal_code" => { ip_geolocation_postal_code: :postal_code },
      "timezone" => { ip_geolocation_timezone: :timezone },
      "continent" => { ip_geolocation_continent_code: :continent_code },
      "metro_code" => { ip_geolocation_metro_code: :metro_code }
    }.freeze

    class << self
      # The source location of a freshly built Configuration's default IP-address
      # reader. See `#ip_address_reader_name` for why this is a comparison
      # against a fresh object rather than against a constant.
      def default_ip_address_reader_source_location
        return @default_ip_address_reader_source_location if defined?(@default_ip_address_reader_source_location)

        @default_ip_address_reader_source_location =
          begin
            Configuration.new.read_ip_address_from_http_request_with.source_location
          rescue StandardError
            nil
          end
      end
    end

    # `policy:` accepts a compiled Clickwrap::Policy or the RequestEvidencePolicy
    # it carries, so a test can hand this class an allowlist directly.
    # `http_request:` is nil for captures that genuinely have no request, and
    # that absence is recorded rather than papered over.
    def initialize(policy:, http_request: nil, capture_channel: nil)
      @policy = policy.respond_to?(:request_evidence) ? policy.request_evidence : policy
      @http_request = http_request
      @capture_channel = capture_channel&.to_s
    end

    def extract
      return Resolved.none(authorized_fields: authorized_fields) unless records_anything?

      attributes = { authorized_fields: authorized_fields }
                   .merge(ip_address_attributes)
                   .merge(browser_user_agent_attributes)
                   .merge(ip_geolocation_attributes)

      Resolved.new(attributes: attributes.freeze, authorized_fields: authorized_fields,
                   records_anything: true)
    end

    private

    attr_reader :policy, :http_request, :capture_channel

    def config = Clickwrap.config
    def policy_key = policy.policy_key

    # One clock reading for the whole extraction, so every field recorded in
    # this capture shares one recorded-at and one retention deadline.
    def now = @now ||= Clickwrap.now

    # --- The compiled decision ------------------------------------------------

    def ip_address_setting = policy.ip_address
    def browser_user_agent_setting = policy.browser_user_agent
    def ip_geolocation_setting = policy.ip_geolocation

    def declared_ip_geolocation_fields = policy.ip_geolocation_fields

    def enabled_ip_geolocation_fields
      @enabled_ip_geolocation_fields ||= declared_ip_geolocation_fields.select { |_, on| on }.keys.freeze
    end

    def authorized_ip_geolocation_field?(field) = declared_ip_geolocation_fields.fetch(field, false)

    def records_ip_address? = ip_address_setting.record?
    def records_browser_user_agent? = browser_user_agent_setting.record?
    def records_ip_geolocation? = ip_geolocation_setting.record? && enabled_ip_geolocation_fields.any?

    def records_anything?
      records_ip_address? || records_browser_user_agent? || records_ip_geolocation?
    end

    # The manifest stored beside the values. It answers "what was this server
    # allowed to keep", which is the question an auditor actually has, and it
    # answers it from the policy rather than from whatever survived.
    def authorized_fields
      @authorized_fields ||= {
        "ip_address" => records_ip_address?,
        "browser_user_agent" => records_browser_user_agent?,
        "ip_geolocation" => records_ip_geolocation? ? declared_ip_geolocation_fields : no_ip_geolocation_fields
      }.freeze
    end

    def no_ip_geolocation_fields
      @no_ip_geolocation_fields ||= Vocabulary::IP_GEOLOCATION_DATA_FIELDS.to_h { |field| [field, false] }.freeze
    end

    # --- The IP address -------------------------------------------------------

    # Resolved once, whether or not the address itself is stored: a policy may
    # estimate a country from an address it never keeps, and that is a smaller
    # collection than keeping the address, not a larger one.
    def observed_ip_address
      read_ip_address_once unless defined?(@observed_ip_address)
      @observed_ip_address
    end

    def ip_address_problem_reason
      read_ip_address_once unless defined?(@observed_ip_address)
      @ip_address_problem_reason
    end

    def read_ip_address_once
      @observed_ip_address = nil
      @ip_address_problem_reason = nil

      return @ip_address_problem_reason = missing_http_request_reason if http_request.nil?

      value, failure = read_from_http_request(config.read_ip_address_from_http_request_with,
                                              "ip_address_reader")
      return @ip_address_problem_reason = failure if failure

      classify_ip_address(value.to_s.strip)
    end

    def classify_ip_address(value)
      if value.empty?
        @ip_address_problem_reason = NO_IP_ADDRESS_ON_HTTP_REQUEST
      elsif value.include?(",")
        # A comma means the reader handed back a forwarding chain rather than
        # one observed address. Clickwrap will not store it. Everything after
        # the first trusted hop in such a chain is client-supplied and can be
        # anything at all, and a whole chain filed under "the address the server
        # observed" presents attacker-controlled input as an observation. A host
        # whose topology needs a different address picks it in its own reader
        # and owns that decision.
        @ip_address_problem_reason = FORWARDED_CHAIN_REFUSED
      else
        @observed_ip_address = value
      end
    end

    def ip_address_attributes
      return {} unless records_ip_address?

      # Provenance is recorded even when the value is not, because "which reader
      # was asked, under which reviewed proxy configuration" is what tells a
      # later reader how much the address is worth.
      provenance = {
        ip_address_reader_name: ip_address_reader_name,
        trusted_proxy_configuration_digest: policy.trusted_proxy_configuration_digest
      }

      if observed_ip_address.nil?
        fail_closed!(:ip_address, ip_address_setting, ip_address_problem_reason)
        return provenance.merge(ip_address_unavailable_reason: ip_address_problem_reason)
      end

      provenance
        .merge(ip_address_ciphertext: observed_ip_address, ip_address_recorded_at: now)
        .merge(retention_attributes(:ip_address, ip_address_setting))
    end

    # Rails documents that `request.remote_ip` inspects forwarded headers,
    # discards configured trusted proxies, and performs a spoof check — and that
    # it can be wrong when the deployment does not match the proxy topology it
    # was told about. Recording which reader produced the value is what lets a
    # later reader judge that, so the label has to be accurate.
    #
    # The default reader is a lambda built per Configuration instance, so there
    # is no constant to compare against; a fresh Configuration's reader gives us
    # its source location instead. A host that assigns its own reader is labeled
    # `host_configured_reader` even if the body is identical, which is the
    # conservative answer: the host owns and documents that decision, and
    # Clickwrap should not claim Rails' behavior on its behalf.
    def ip_address_reader_name
      default_location = self.class.default_ip_address_reader_source_location
      reader = config.read_ip_address_from_http_request_with

      return HOST_CONFIGURED_READER_NAME if default_location.nil?
      return HOST_CONFIGURED_READER_NAME unless reader.respond_to?(:source_location)
      return HOST_CONFIGURED_READER_NAME unless reader.source_location == default_location

      RAILS_REQUEST_REMOTE_IP_READER_NAME
    end

    # --- The browser user-agent -----------------------------------------------

    def observed_browser_user_agent
      read_browser_user_agent_once unless defined?(@observed_browser_user_agent)
      @observed_browser_user_agent
    end

    def browser_user_agent_problem_reason
      read_browser_user_agent_once unless defined?(@observed_browser_user_agent)
      @browser_user_agent_problem_reason
    end

    def read_browser_user_agent_once
      @observed_browser_user_agent = nil
      @browser_user_agent_problem_reason = nil

      return @browser_user_agent_problem_reason = missing_http_request_reason if http_request.nil?

      value, failure = read_from_http_request(config.read_browser_user_agent_from_http_request_with,
                                              "browser_user_agent_reader")
      return @browser_user_agent_problem_reason = failure if failure

      value = value.to_s.strip
      if value.empty?
        @browser_user_agent_problem_reason = NO_BROWSER_USER_AGENT_ON_HTTP_REQUEST
      else
        @observed_browser_user_agent = value
      end
    end

    def browser_user_agent_attributes
      return {} unless records_browser_user_agent?

      # Always true, and not a formality. The value is whatever the client chose
      # to send: it can be edited or omitted, and browsers report less of it
      # every year. Recording that it was client-supplied is what stops a
      # receipt from reading like a device identification. Clickwrap stores the
      # raw header only — no canvas, font, hardware, or high-entropy client-hint
      # probe is emitted anywhere in this gem.
      base = { browser_user_agent_was_client_supplied: true }

      if observed_browser_user_agent.nil?
        fail_closed!(:browser_user_agent, browser_user_agent_setting, browser_user_agent_problem_reason)
        return base.merge(browser_user_agent_unavailable_reason: browser_user_agent_problem_reason)
      end

      base
        .merge(browser_user_agent_ciphertext: observed_browser_user_agent,
               browser_user_agent_recorded_at: now)
        .merge(retention_attributes(:browser_user_agent, browser_user_agent_setting))
    end

    # --- The IP geolocation estimate ------------------------------------------

    def resolver
      @resolver ||= config.ip_geolocation_resolver_for(policy.ip_geolocation_resolver_name) ||
                    IpGeolocation::NullResolver.new
    end

    def resolved_location
      return @resolved_location if defined?(@resolved_location)

      @resolver_error = nil
      @resolved_location = observed_ip_address.nil? ? nil : call_resolver
    end

    def call_resolver
      resolver.resolve(observed_ip_address)
    rescue StandardError => error
      # Recorded, never swallowed. The reason carries the error CLASS and never
      # its message: a provider's message can quote the address it was given,
      # and this string lands in a column that a redacted receipt may show.
      @resolver_error = error
      nil
    end

    def ip_geolocation_attributes
      return {} unless records_ip_geolocation?

      location = resolved_location
      values = location.nil? ? {} : authorized_ip_geolocation_values(location)
      reason = ip_geolocation_problem_reason(location, values)
      provenance = ip_geolocation_provenance(location)

      if reason
        fail_closed!(:ip_geolocation, ip_geolocation_setting, reason)
        return provenance.merge(ip_geolocation_unavailable_reason: reason)
      end

      provenance
        .merge(values)
        .merge(ip_geolocation_recorded_at: now)
        .merge(retention_attributes(:ip_geolocation, ip_geolocation_setting))
    end

    # Provenance is not optional and not a policy choice. A country code with no
    # provider behind it, or coordinates with no resolution time, invites a
    # reader to treat a guess about an address as a fact about a person. These
    # columns travel with any stored estimate and with every failure to produce
    # one.
    def ip_geolocation_provenance(location)
      {
        ip_geolocation_provider_name: text_value(location&.provider_name),
        ip_geolocation_provider_source: text_value(location&.provider_source),
        ip_geolocation_database_version: text_value(location&.database_version),
        ip_geolocation_database_sha256: text_value(location&.database_sha256),
        # An IP-geolocation result is an estimate about an address. Nothing a
        # resolver reports and nothing a policy enables changes that.
        ip_geolocation_was_estimated: location.nil? || location.estimated?,
        ip_geolocation_source_was_verified_by_host: location&.source_was_verified_by_host? || false,
        # Resolution time is not optional either. When a resolver does not
        # report one, the server's own clock at extraction stands in — which is
        # what the column means anyway: time recorded by the application server.
        ip_geolocation_resolved_at: location&.resolved_at || now
      }
    end

    # Five distinct ways this can produce nothing, kept distinct because they
    # tell an auditor completely different things: there was no address to
    # resolve; the resolver blew up; it returned nothing at all; it explained
    # why it had no answer; or it answered but had no value for any field this
    # policy authorized. The last one splits again — a provider that CANNOT ever
    # supply the authorized fields is a configuration problem, while one that
    # simply had no value for this address is not.
    def ip_geolocation_problem_reason(location, values)
      return ip_address_problem_reason if observed_ip_address.nil?
      return truncate("ip_geolocation_resolver_raised_#{@resolver_error.class}") if @resolver_error
      return RESOLVER_RETURNED_NO_RESULT if location.nil?
      return truncate(location.unavailable_reason) if location.unavailable?
      return nil if values.any?

      return PROVIDER_SUPPLIED_NO_AUTHORIZED_FIELD if resolver_can_supply_an_authorized_field?

      RESOLVER_CANNOT_SUPPLY_AUTHORIZED_FIELDS
    end

    def resolver_can_supply_an_authorized_field?
      capabilities = resolver_capabilities
      return true if capabilities.nil?

      enabled_ip_geolocation_fields.intersect?(capabilities)
    end

    def resolver_capabilities
      return nil unless resolver.respond_to?(:capabilities)

      Array(resolver.capabilities).map(&:to_s)
    rescue StandardError, NotImplementedError
      # A resolver that cannot say what it supports gets the benefit of the
      # doubt: Clickwrap reports that the provider had no value, rather than
      # accusing it of being unable to supply one.
      nil
    end

    # Exactly the fields the server-owned policy authorized, copied one at a
    # time. The resolver's result object is never persisted wholesale: a
    # provider that gains a field upstream must never widen what this gem stores
    # without someone deciding to store it.
    def authorized_ip_geolocation_values(location)
      ip_geolocation_data_field_values(location).compact.merge(accuracy_radius_values(location))
    end

    def ip_geolocation_data_field_values(location)
      values = TEXT_COLUMNS_BY_AUTHORIZED_FIELD.each_with_object({}) do |(field, columns), collected|
        next unless authorized_ip_geolocation_field?(field)

        columns.each { |column, reader| collected[column] = text_value(location.public_send(reader)) }
      end

      values.merge(coordinate_values(location))
    end

    # One coupled choice, and `coordinates?` is the reason it is written as a
    # pair: half a coordinate is not a result, and a latitude presented on its
    # own would be read as one.
    def coordinate_values(location)
      return {} unless authorized_ip_geolocation_field?("latitude_and_longitude")
      return {} unless location.coordinates?

      { ip_geolocation_latitude: location.latitude, ip_geolocation_longitude: location.longitude }
    end

    # The confidence percentage travels with the radius it qualifies. It is not
    # separately selectable, for the same reason the radius is not separately
    # discardable: a number of kilometres means nothing without the confidence
    # the provider attaches to it.
    def accuracy_radius_values(location)
      return {} unless location.accuracy_radius?
      return {} unless authorized_ip_geolocation_field?("accuracy_radius_in_kilometers")

      {
        ip_geolocation_accuracy_radius_in_kilometers:
          integer_value(location.accuracy_radius_in_kilometers),
        ip_geolocation_accuracy_radius_confidence_percentage:
          integer_value(location.accuracy_radius_confidence_percentage)
      }.compact
    end

    # --- Retention ------------------------------------------------------------

    # Every recorded field leaves here with a disposal rule: a date, or the name
    # of a host rule that will produce one. There is no keep-forever default
    # anywhere in this gem, and a recorded field with neither is a configuration
    # bug caught before the row is written rather than a row nobody ever deletes.
    #
    # `retain_until` names a host calculation instead of a duration because real
    # record-keeping schedules are not always durations — "five years, or three
    # years after this contract is liquidated, whichever is later" cannot be
    # expressed as a number of days at capture time.
    def retention_attributes(category, setting)
      return { "#{category}_delete_after": now + setting.delete_after } if setting.delete_after
      return { "#{category}_retain_until_rule": setting.retain_until.to_s } if setting.retain_until

      class_rule = retention_class_rule_for(category)
      return { "#{category}_delete_after": now + class_rule.duration } if class_rule&.duration?
      return { "#{category}_retain_until_rule": class_rule.host_event_name.to_s } if class_rule&.host_event?

      raise ConfigurationError, missing_retention_message(category)
    end

    def retention_class_rule_for(category)
      return nil if policy.retention_class_key.nil?

      Clickwrap.retention_class!(policy.retention_class_key).rule_for(category)
    end

    def missing_retention_message(category)
      "Clickwrap is about to record #{category} for policy #{policy_key} and nothing says when " \
        "to delete it. Give the policy a rule — `delete_after:` with a reviewed period, or " \
        "`retain_until:` naming a host retention calculation — or add a #{category} rule to " \
        "retention class #{policy.retention_class_key.inspect}. Clickwrap has no keep-forever " \
        "default and will not choose a period for you."
    end

    # --- Failing closed -------------------------------------------------------

    # A policy can decide that evidence it cannot get is worse than no capture
    # at all. When it has, the capture and the protected action roll back
    # together; nothing is written half-formed.
    #
    # The message names the policy, the category, and the reason, and never the
    # value: an exception message travels into logs, error trackers, and issue
    # trackers, which is exactly where a recorded IP address must not appear.
    def fail_closed!(category, setting, reason)
      requirement = requirement_for(category, setting)
      return if requirement.nil?

      raise RequestEvidenceUnavailable,
            "Policy #{policy_key} records #{category} and #{requirement}, but this capture " \
            "could not supply it (#{reason}). Nothing was written: required request evidence " \
            "and the action it protects commit together or not at all. Either capture from a " \
            "request that carries the value#{channel_note}, or drop that requirement and accept " \
            "an explicit unavailable state on the receipt."
    end

    def requirement_for(_category, setting)
      return "the policy sets `fail_if_unavailable: true`" if setting.fail_if_unavailable?

      nil
    end

    def channel_note
      return "" if capture_channel.nil?

      " (this one arrived on the #{capture_channel} channel)"
    end

    # --- Shared helpers -------------------------------------------------------

    def missing_http_request_reason
      return CHANNEL_CARRIES_NO_HTTP_REQUEST if CHANNELS_WITHOUT_AN_HTTP_REQUEST.include?(capture_channel)

      NO_HTTP_REQUEST
    end

    # Returns `[value, failure_reason]`. A host reader can raise — Rails' own
    # raises `IpSpoofAttackError` when the forwarded headers contradict each
    # other, which is a genuinely useful thing to find written on a receipt.
    # The failure becomes an unavailable state naming the error class, and a
    # policy that requires the field still fails closed on it.
    def read_from_http_request(reader, label)
      [reader.call(http_request), nil]
    rescue StandardError => error
      [nil, truncate("#{label}_raised_#{error.class}")]
    end

    def text_value(value)
      return nil if value.nil?

      string = value.to_s.strip
      string.empty? ? nil : string
    end

    def integer_value(value)
      return nil if value.nil?
      return nil if value.to_s.strip.empty?

      Integer(value, exception: false) || Float(value, exception: false)&.round
    end

    def truncate(reason)
      reason.to_s[0, MAXIMUM_UNAVAILABLE_REASON_LENGTH]
    end
  end
end
