# frozen_string_literal: true

module Clickwrap
  module DSL
    # The block passed to `Clickwrap.retention`.
    #
    #   Clickwrap.retention :ordinary_agreement_evidence do
    #     retain_core_event_for 6.years
    #     delete_recorded_ip_address_after 90.days
    #     delete_recorded_browser_user_agent_after 90.days
    #     delete_recorded_ip_geolocation_after 90.days
    #   end
    #
    # Two vocabularies on purpose. `retain_..._for` and `retain_..._until` say
    # how long evidence is kept; `delete_..._after` says when personal request
    # evidence goes away. They read differently because they are different
    # intentions, and the second one is the destructive one.
    class RetentionBuilder
      def initialize(key)
        @key = key.to_s
        @rules = {}
      end

      # --- The core event -------------------------------------------------------

      def retain_core_event_for(duration)
        assign_rule!(:core_event, duration:)
      end

      # The default, said out loud. Omitting the core-event rule means the same
      # thing, but a retention class somebody will read in review is better off
      # carrying the decision in words.
      def retain_core_event_indefinitely
        assign_rule!(:core_event, indefinite: true)
      end

      # For obligations a duration cannot express — "five years, or three years
      # after this contract is liquidated, whichever is later". The named
      # calculation is registered by the host on the configuration object, and
      # it may legitimately return nil while the triggering event has not
      # happened, in which case the record is simply not due yet.
      def retain_core_event_until(host_event_name)
        assign_rule!(:core_event, host_event_name:)
      end

      # --- Optional request evidence -------------------------------------------

      def delete_recorded_ip_address_after(duration)
        assign_rule!(:ip_address, duration:)
      end

      def delete_recorded_browser_user_agent_after(duration)
        assign_rule!(:browser_user_agent, duration:)
      end

      def delete_recorded_ip_geolocation_after(duration)
        assign_rule!(:ip_geolocation, duration:)
      end

      def retain_recorded_ip_address_until(host_event_name)
        assign_rule!(:ip_address, host_event_name:)
      end

      def retain_recorded_browser_user_agent_until(host_event_name)
        assign_rule!(:browser_user_agent, host_event_name:)
      end

      def retain_recorded_ip_geolocation_until(host_event_name)
        assign_rule!(:ip_geolocation, host_event_name:)
      end

      def compile = RetentionClass.new(key: @key, rules: @rules)

      private

      def assign_rule!(part, duration: nil, host_event_name: nil, indefinite: false)
        if @rules.key?(part)
          raise DefinitionError,
                "Retention class #{@key} declares #{part} more than once. Keep one reviewed " \
                "rule for each part; Clickwrap will not let line order silently replace a " \
                "deletion deadline."
        end

        @rules[part] = RetentionClass::Rule.new(part:, duration:, host_event_name:, indefinite:)
      end

      def method_missing(name, *_arguments, **_options)
        raise DefinitionError,
              "Retention class #{@key} calls unknown DSL method `#{name}`. Check the spelling; " \
              "Clickwrap never ignores retention declarations."
      end

      def respond_to_missing?(_name, _include_private = false) = false
    end
  end
end
