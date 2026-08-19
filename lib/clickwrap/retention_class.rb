# frozen_string_literal: true

module Clickwrap
  # An application-defined retention class: how long each part of an event is
  # kept, and what triggers the clock.
  #
  #   Clickwrap.retention :ordinary_agreement_evidence do
  #     retain_core_event_indefinitely
  #     delete_recorded_ip_address_after 6.years
  #     delete_recorded_browser_user_agent_after 6.years
  #   end
  #
  # The default — for any part not given a rule, the core event included — is
  # to keep the evidence indefinitely. That direction is deliberate: keeping is
  # reversible (a reviewed disposition can always run later) while deletion is
  # not, and the day contractual evidence matters is usually years away.
  # Deletion is therefore the explicit, reviewed act, never a default.
  #
  # Clickwrap does not choose deletion periods and cannot tell you whether
  # yours are right. What it does is make a reviewed decision executable and
  # auditable, keep the core event's schedule separate from the optional
  # personal request evidence, and delegate event-based or "later of" rules to
  # a named host calculation. The host owns that calculation because a fixed
  # duration cannot express "five years, or three years after this contract is
  # liquidated, whichever is later" without application domain state.
  class RetentionClass
    PARTS = %i[core_event ip_address browser_user_agent ip_geolocation].freeze

    # A rule is a duration from the event's server-recorded time, the name of a
    # host-registered calculation that may depend on domain state and may not
    # be resolvable yet — or the explicit decision to keep the part forever.
    Rule = Data.define(:part, :duration, :host_event_name, :indefinite) do
      def initialize(part:, duration: nil, host_event_name: nil, indefinite: false)
        super
      end

      def duration? = !duration.nil?
      def host_event? = !host_event_name.nil?
      def indefinite? = indefinite

      def to_snapshot
        {
          "duration_seconds" => duration&.to_i,
          "host_event" => host_event_name&.to_s,
          "indefinite" => (true if indefinite)
        }.compact
      end
    end

    attr_reader :key, :rules

    def initialize(key:, rules:)
      @key = key.to_s
      # A part with no declared rule is kept indefinitely. For the core event
      # that default is made explicit here, so every consumer — the planner,
      # the privacy inventory, the snapshot on a plan — sees a reviewed answer
      # ("indefinite") rather than a silence it must interpret.
      rules = rules.dup
      rules[:core_event] ||= Rule.new(part: :core_event, indefinite: true)
      @rules = rules.freeze

      validate!
      freeze
    end

    def rule_for(part) = rules[part.to_sym]

    def to_snapshot
      {
        "key" => key,
        "rules" => rules.to_h { |part, rule| [part.to_s, rule.to_snapshot] }
      }
    end

    private

    def validate!
      unknown = rules.keys - PARTS
      unless unknown.empty?
        raise DefinitionError,
              "Retention class #{key} declares rules for #{unknown.join(", ")}, which are not " \
              "parts of an event. Choose from: #{PARTS.join(", ")}."
      end

      rules.each_value do |rule|
        if [rule.duration?, rule.host_event?, rule.indefinite?].count(true) != 1
          raise DefinitionError,
                "Retention class #{key} must give #{rule.part} exactly one schedule: a " \
                "duration, a named host calculation, or indefinite — never a combination " \
                "and never none."
        end

        if rule.host_event? && rule.host_event_name.to_s.strip.empty?
          raise DefinitionError,
                "Retention class #{key} gives #{rule.part} a blank host calculation name. " \
                "Name the calculation registered with `config.calculate_retention_time_for`."
        end

        next unless rule.duration? && rule.duration.to_i <= 0

        raise DefinitionError,
              "Retention class #{key} keeps #{rule.part} for #{rule.duration.inspect}, which is " \
              "not a period."
      end
    end
  end
end
