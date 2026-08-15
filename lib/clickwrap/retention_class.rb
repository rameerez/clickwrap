# frozen_string_literal: true

module Clickwrap
  # An application-defined retention class: how long each part of an event is
  # kept, and what triggers the clock.
  #
  #   Clickwrap.retention :ordinary_agreement_evidence do
  #     retain_core_event_for 6.years
  #     delete_recorded_ip_address_after 90.days
  #     delete_recorded_browser_user_agent_after 90.days
  #     delete_recorded_ip_geolocation_after 90.days
  #   end
  #
  # Clickwrap does not choose these periods and cannot tell you whether yours
  # are right. What it does is make a reviewed decision executable and
  # auditable, keep the core event's schedule separate from the optional
  # personal request evidence, and support the event-based and "later of" rules
  # that real record-keeping obligations actually use — because a fixed
  # duration cannot express "five years, or three years after this contract is
  # liquidated, whichever is later".
  class RetentionClass
    PARTS = %i[core_event ip_address browser_user_agent ip_geolocation].freeze

    # A rule is either a duration from the event's server-recorded time, or the
    # name of a host-registered calculation that may depend on domain state and
    # may not be resolvable yet.
    Rule = Data.define(:part, :duration, :host_event_name) do
      def initialize(part:, duration: nil, host_event_name: nil)
        super
      end

      def duration? = !duration.nil?
      def host_event? = !host_event_name.nil?

      def to_snapshot
        { "duration_seconds" => duration&.to_i, "host_event" => host_event_name&.to_s }.compact
      end
    end

    attr_reader :key, :rules

    def initialize(key:, rules:)
      @key = key.to_s
      @rules = rules.freeze

      validate!
      freeze
    end

    def rule_for(part) = rules[part.to_sym]

    # Returns the time this part becomes eligible for disposition, or nil when
    # the rule depends on a host event that has not happened yet. A nil is a
    # real answer here — "not yet due, and we cannot say when" — and the
    # disposition planner reports it rather than guessing a date.
    def eligible_at(part, event:)
      rule = rule_for(part)
      return nil if rule.nil?

      if rule.duration?
        recorded_at(event) + rule.duration
      else
        Clickwrap.configuration.resolve_retention_time(rule.host_event_name, event)
      end
    end

    def retains_core_event_forever?
      rule_for(:core_event).nil?
    end

    def to_snapshot
      {
        "key" => key,
        "rules" => rules.to_h { |part, rule| [part.to_s, rule.to_snapshot] }
      }
    end

    private

    def recorded_at(event)
      event.respond_to?(:recorded_at_by_server) ? event.recorded_at_by_server : event[:recorded_at_by_server]
    end

    def validate!
      unknown = rules.keys - PARTS
      unless unknown.empty?
        raise DefinitionError,
              "Retention class #{key} declares rules for #{unknown.join(", ")}, which are not " \
              "parts of an event. Choose from: #{PARTS.join(", ")}."
      end

      rules.each_value do |rule|
        next unless rule.duration? && rule.duration.to_i <= 0

        raise DefinitionError,
              "Retention class #{key} keeps #{rule.part} for #{rule.duration.inspect}, which is " \
              "not a period."
      end

      return if rules.key?(:core_event)

      raise DefinitionError,
            "Retention class #{key} never says how long to keep the core event. Use " \
            "`retain_core_event_for 6.years` or `retain_core_event_until :your_host_event`. " \
            "Clickwrap has no forever default, and it will not pick a period for you."
    end
  end
end
