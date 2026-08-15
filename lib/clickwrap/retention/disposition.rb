# frozen_string_literal: true

module Clickwrap
  module Retention
    # The two destructive operations in the whole gem, in one place.
    #
    #   Clickwrap::Retention::Disposition.delete_field!(receipt, :ip_address, because: "...")
    #   Clickwrap::Retention::Disposition.dispose_core_event!(event, because: "...")
    #
    # Both name exactly what they remove, both require a reason in plain
    # English, both refuse while a legal hold is in effect, and both append
    # their own event saying what went and why. There is deliberately no
    # `delete_personal_data!`, no `purge_network_context!`, and no method that
    # takes out three categories at once: someone reading a disposition report
    # a year from now has to be able to see which field disappeared, not a
    # euphemism covering several.
    #
    # These back the public `Clickwrap.delete_recorded_ip_address!`,
    # `Clickwrap.delete_recorded_browser_user_agent!`, and
    # `Clickwrap.delete_recorded_ip_geolocation!`.
    module Disposition
      FIELDS = %i[ip_address browser_user_agent ip_geolocation].freeze

      # Everything an IP-geolocation deletion nulls: the estimated values
      # themselves, and nothing else.
      #
      # What deliberately stays is the provenance of what was there and of its
      # removal — which provider estimated it, from which database version, how
      # uncertain it was, when it was recorded, under which rule it was due, and
      # when it was deleted. Those columns are not the personal estimate; they
      # are the record that an estimate existed and was disposed of on schedule.
      # Erasing them too would turn a documented deletion into a gap, which is
      # the one outcome a retention process must never produce.
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

      # One category, one set of columns. The raw values are the only things
      # that go; the reader name, the trusted-proxy configuration digest, and
      # the recorded-at timestamp explain where the deleted value came from.
      COLUMNS_FOR_FIELD = {
        ip_address: %w[ip_address_ciphertext].freeze,
        browser_user_agent: %w[browser_user_agent_ciphertext].freeze,
        ip_geolocation: IP_GEOLOCATION_VALUE_COLUMNS
      }.freeze

      class << self
        # Deletes one recorded request-evidence field from the annex attached to
        # this event, and records that it did.
        #
        # Returns the appended disposition event, or nil when there was nothing
        # to delete — no annex, nothing recorded for that field, or the field
        # already deleted. A no-op appends no event, because an event saying
        # "deleted" where nothing was ever recorded would be false.
        def delete_field!(receipt_or_event, field, because:)
          field = normalize_field!(field)
          require_reason!(because, "Deleting the recorded #{field}")

          event = event_for(receipt_or_event)
          refuse_while_on_legal_hold!(event, "the recorded #{field}")

          # Read the annex from the database rather than through whatever the
          # caller's object happens to have cached. A deletion has to be decided
          # on the row as it stands right now, and a receipt handed around a
          # request cycle may have loaded its annex several queries ago.
          annex = RequestEvidence.find_by(event_id: event.id)
          return nil if annex.nil?
          return nil if annex.deleted_for?(field)
          return nil if annex.public_send(:"#{field}_recorded_at").nil?

          delete_annex_field!(annex, event, field, because)
        end

        # Marks a core event disposed of under its retention rule.
        #
        # The row stays. What changes is `core_event_disposed_at`, which is one
        # of the three columns the append-only Event model permits, and a linked
        # `disposition` event that explains it. An auditor then reads a
        # documented disposition rather than finding a hole where an agreement
        # used to be, and verification of the surrounding chain still works.
        def dispose_core_event!(event, because:)
          event = event_for(event)
          require_reason!(because, "Disposing of the core event")
          refuse_while_on_legal_hold!(event, "the core event")

          # Same reasoning as the annex: `core_event_disposed_at` is one of the
          # three columns that can change after an event is written, so it is
          # read fresh instead of trusted from a loaded object. Appending a
          # second disposition event for a disposition that already happened
          # would put an event in the record that describes nothing.
          return nil if Event.where(id: event.id).pick(:core_event_disposed_at).present?

          ::ActiveRecord::Base.transaction do
            event.mark_core_event_disposed!

            Lifecycle.append_lifecycle_event!(
              event: event,
              event_type: "disposition",
              reason: "Disposed of the core event under its retention rule. #{because}"
            )
          end
        end

        # Whether disposition is currently paused for this event by a hold on
        # the event itself, on the actor, or on the policy. All three scopes
        # count: a hold placed on an actor's whole file is not weaker than one
        # placed on a single receipt.
        def legal_hold_in_effect?(event)
          return true if event.on_legal_hold?

          holds = LegalHold.in_effect
          return true if holds.where(scope: "event", event_id: event.id).exists?
          return true if event.actor_reference.present? &&
                         holds.where(scope: "actor", actor_reference: event.actor_reference).exists?

          holds.where(scope: "policy", policy_key: event.policy_key).exists?
        end

        # Resolves a receipt, an event, or an event id to the event itself, so
        # the public methods read naturally from either end.
        def event_for(receipt_or_event)
          return receipt_or_event if receipt_or_event.is_a?(Event)
          return receipt_or_event.event if receipt_or_event.respond_to?(:event)
          return Receipt.find(receipt_or_event.to_s).event if receipt_or_event.is_a?(String)

          raise ArgumentError,
                "Disposition needs a Clickwrap receipt, event, or event id, got " \
                "#{receipt_or_event.class}."
        end

        private

        # The deletion itself, plus the event that documents it, in one
        # transaction. Either both happen or neither does: a value that
        # disappeared with no record of who removed it and why is exactly the
        # thing this gem exists to prevent.
        #
        # Two things this deliberately does NOT touch:
        #
        #   * the core event's columns, and
        #   * the event's `request_evidence_digest`.
        #
        # The event's canonical body excludes every annex value on purpose (see
        # Clickwrap::Receipt), so an ordinary retention run cannot make a
        # verified event stop verifying — deletion changes what a receipt can
        # show, never what it says happened. The keyed binding digest recorded
        # at capture stays as written; after this runs it no longer recomputes
        # from the annex, and that is the expected, documented consequence of a
        # permitted deletion rather than a sign of tampering. The receipt
        # reports the field as `deleted_after_retention` with the timestamp, so
        # a reader is told which it is.
        def delete_annex_field!(annex, event, field, because)
          ::ActiveRecord::Base.transaction do
            annex.update!(
              COLUMNS_FOR_FIELD.fetch(field).to_h { |column| [column, nil] }
                               .merge("#{field}_deleted_at" => Clickwrap.now)
            )

            Lifecycle.append_lifecycle_event!(
              event: event,
              event_type: "disposition",
              reason: "Deleted the recorded #{field}. #{because}"
            )
          end
        end

        def normalize_field!(field)
          normalized = field.to_s.to_sym
          return normalized if FIELDS.include?(normalized)

          raise ArgumentError,
                "#{field.inspect} is not a request-evidence field Clickwrap can delete. " \
                "Choose one of: #{FIELDS.join(", ")}. Each one is deleted by name so a " \
                "disposition report can say which value went."
        end

        def require_reason!(because, what)
          return unless because.to_s.strip.empty?

          raise LifecycleError,
                "#{what} needs a `because:` in plain English. It is stored on the disposition " \
                "event, and it is the only thing that will explain this deletion to someone " \
                "reading the record years from now."
        end

        def refuse_while_on_legal_hold!(event, what)
          return unless legal_hold_in_effect?(event)

          raise LegalHoldInEffect,
                "A legal hold is in effect for event #{event.id}, so #{what} was not deleted. " \
                "Release the hold with a reason and an owner first, or exclude this event from " \
                "the disposition. A hold that scheduled deletion could quietly step over would " \
                "not be a hold."
        end
      end
    end
  end
end
