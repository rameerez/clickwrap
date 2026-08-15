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
        @rules[:core_event] = RetentionClass::Rule.new(part: :core_event, duration:)
      end

      # For obligations a duration cannot express — "five years, or three years
      # after this contract is liquidated, whichever is later". The named
      # calculation is registered by the host on the configuration object, and
      # it may legitimately return nil while the triggering event has not
      # happened, in which case the record is simply not due yet.
      def retain_core_event_until(host_event_name)
        @rules[:core_event] = RetentionClass::Rule.new(part: :core_event, host_event_name:)
      end

      # --- Optional request evidence -------------------------------------------

      def delete_recorded_ip_address_after(duration)
        @rules[:ip_address] = RetentionClass::Rule.new(part: :ip_address, duration:)
      end

      def delete_recorded_browser_user_agent_after(duration)
        @rules[:browser_user_agent] = RetentionClass::Rule.new(part: :browser_user_agent, duration:)
      end

      def delete_recorded_ip_geolocation_after(duration)
        @rules[:ip_geolocation] = RetentionClass::Rule.new(part: :ip_geolocation, duration:)
      end

      def retain_recorded_ip_address_until(host_event_name)
        @rules[:ip_address] = RetentionClass::Rule.new(part: :ip_address, host_event_name:)
      end

      def retain_recorded_browser_user_agent_until(host_event_name)
        @rules[:browser_user_agent] = RetentionClass::Rule.new(part: :browser_user_agent, host_event_name:)
      end

      def retain_recorded_ip_geolocation_until(host_event_name)
        @rules[:ip_geolocation] = RetentionClass::Rule.new(part: :ip_geolocation, host_event_name:)
      end

      def compile = RetentionClass.new(key: @key, rules: @rules)
    end
  end
end
