# frozen_string_literal: true

module Clickwrap
  # What the application configured, what one actor's evidence contains, and
  # what a disposition of it would look like.
  #
  # ============================================================================
  # THIS MODULE DESCRIBES A CONFIGURATION. Describing a configuration is not the
  # same as the configuration being lawful, proportionate, or adequately
  # justified. `inventory` reads back the fields this application chose to
  # record, the purposes it wrote down, the references it supplied, and the
  # periods it set. It does not evaluate any of them. A complete inventory with
  # every field filled in is a well-documented configuration, and nothing more;
  # the lawful basis, the necessity, the proportionality, the retention period,
  # and the answer to an erasure request all belong to the host application and
  # its counsel.
  # ============================================================================
  #
  #   Clickwrap::Privacy.inventory
  #   Clickwrap::Privacy.export_for(user, requested_by: current_operator)
  #   Clickwrap::Privacy.plan_disposition_for(user, requested_by: operator, because: "DSAR-2026-41")
  module Privacy
    CATEGORIES = %i[ip_address browser_user_agent ip_geolocation].freeze

    # Used only to tell a host-supplied callback apart from the gem's own
    # declining default when the inventory reports where a decision is made.
    GEM_LIB_ROOT = File.expand_path("..", __dir__)

    class << self
      # A structured description of what this application configured: every
      # policy, every personal or request-derived field it enables, the stated
      # purpose, the host-supplied legal-basis and DPIA references, the
      # resolver, the encryption state, the retention rule, the host events that
      # cannot currently be resolved, and the review date.
      def inventory
        {
          "describes" => "configuration",
          "generated_at" => Receipt.format_time(Clickwrap.now),
          "gem_version" => Clickwrap::VERSION,
          "defaults" => default_inventory,
          "access_decisions" => access_decisions,
          "policies" => Clickwrap.policies.values.map { |policy| policy_inventory(policy) },
          "retention_classes" => Clickwrap.retention_classes.values.map { |klass| retention_inventory(klass) },
          "unresolved_host_events" => unresolved_host_events,
          "means" => "The fields this application is configured to record, the purposes it wrote " \
                     "down, and the periods it set. Clickwrap does not assess whether any of them " \
                     "is lawful, necessary, or long enough."
        }
      end

      # One actor's evidence, under exactly the authorization and redaction
      # rules a receipt export uses — the same `because:`, the same host
      # callback, the same field-by-field opt-in, and the same recorded access.
      # There is deliberately no privacy-flavored shortcut that reveals more
      # than `Clickwrap.export_receipt` would.
      def export_for(actor, requested_by:, because: nil, include_ip_address: false,
                     include_browser_user_agent: false, include_ip_geolocation: false)
        reference = reference_for!(actor)

        events = Event.for_actor(reference)
                      .includes(:statements, :documents, :policy_revision, :request_evidence)
                      .chronological

        {
          "actor_reference" => reference,
          "generated_at" => Receipt.format_time(Clickwrap.now),
          "receipt_count" => events.size,
          "receipts" => events.map do |event|
            Receipt.export(
              Receipt.new(event),
              requested_by: requested_by,
              because: because,
              include_ip_address: include_ip_address,
              include_browser_user_agent: include_browser_user_agent,
              include_ip_geolocation: include_ip_geolocation
            )
          end,
          "current_statements" => current_statements_for(reference),
          "means" => "Every Clickwrap event recorded against this actor reference, rendered as " \
                     "receipts with the same redaction rules that apply everywhere else."
        }
      end

      # Creates a reviewable disposition plan for one actor, and NOTHING else.
      #
      # It does not delete anything, does not release a hold, does not decide
      # whether an erasure request overrides a retention duty, a legal claim, or
      # a hold, and does not tell the host which of those apply. What it does is
      # put the whole picture in one reviewable place: what exists, what is
      # still inside its retention period, and what is held — so the person who
      # has to make that decision makes it with the facts in front of them, and
      # so their decision is recorded as a plan somebody else can read.
      def plan_disposition_for(actor, requested_by:, because:)
        require_reason!(because)
        reference = reference_for!(actor)

        items = actor_items(reference)
        held, due = items.partition { |item| item.status == :held }

        DispositionPlan.create!(
          kind: "actor_privacy",
          disposition_scope: {
            "kind" => "actor_privacy",
            "at" => Receipt.format_time(Clickwrap.now),
            "actor_reference" => reference,
            "items" => due.map(&:to_plan_entry)
          },
          summary: actor_summary(reference, due, held),
          item_count: due.length,
          created_by_reference: reference_for(requested_by),
          reason: because
        )
      end

      private

      # --- Inventory ------------------------------------------------------------

      def default_inventory
        config = Clickwrap.config

        {
          "records_any_request_evidence_by_default" => config.records_any_request_evidence_by_default?,
          "ip_address" => default_category(config, :ip_address),
          "browser_user_agent" => default_category(config, :browser_user_agent),
          "ip_geolocation" => default_category(config, :ip_geolocation).merge(
            "fields" => config.enabled_default_ip_geolocation_fields,
            "resolver" => describe_resolver(config.ip_geolocation_resolver),
            "fail_capture_when_unavailable" => config.fail_capture_when_ip_geolocation_is_unavailable
          ),
          "review_default_request_evidence_configuration_on" =>
            config.review_default_request_evidence_configuration_on&.to_s,
          "ip_address_reader" => describe_callback(config.read_ip_address_from_http_request_with),
          "trusted_proxy_configuration_digest" => config.trusted_proxy_configuration_digest,
          "storing_request_evidence_unencrypted" => config.storing_request_evidence_unencrypted?,
          "reason_for_storing_request_evidence_unencrypted" =>
            config.reason_for_storing_request_evidence_unencrypted
        }
      end

      def default_category(config, category)
        {
          "recorded_by_default" => default_recorded?(config, category),
          "because" => config.public_send(:"reason_for_recording_#{plural_for(category)}_by_default"),
          "legal_basis_reference" =>
            config.public_send(:"legal_basis_reference_for_recording_#{plural_for(category)}_by_default"),
          "encrypted" => config.public_send(:"encrypt_recorded_#{plural_for(category)}"),
          "delete_after_seconds" => config.public_send(:"delete_recorded_#{plural_for(category)}_after")&.to_i
        }
      end

      def default_recorded?(config, category)
        case category
        when :ip_address then config.record_ip_address_by_default
        when :browser_user_agent then config.record_browser_user_agent_by_default
        else config.enabled_default_ip_geolocation_fields.any?
        end
      end

      def policy_inventory(policy)
        request_evidence = policy.request_evidence
        retention_class = Clickwrap.retention_classes[policy.retention_class_key.to_s]

        {
          "policy" => policy.key,
          "retention_class" => policy.retention_class_key,
          "records_any_request_evidence" => request_evidence.records_anything?,
          "fields" => CATEGORIES.to_h do |category|
            [category.to_s, policy_category(policy, category, retention_class)]
          end,
          "review_request_evidence_configuration_on" => request_evidence.review_configuration_on&.to_s,
          "unresolved_host_events" => unresolved_host_events_for(policy, retention_class),
          "persists_presentations_for_seconds" => policy.persist_presentations_for&.to_i,
          "persists_presentations_because" => policy.persist_presentations_because
        }
      end

      # One line per category per policy, with the purpose and the references
      # the host supplied kept as the host's own words. Clickwrap stores them
      # and prints them back; it never rewrites them into something that reads
      # like an assessment it made.
      def policy_category(policy, category, retention_class)
        setting = policy.request_evidence.setting_for(category)
        rule = retention_class&.rule_for(category)

        entry = {
          "recorded" => setting.record?,
          "because" => setting.because,
          "legal_basis_reference" => setting.legal_basis_reference,
          "data_protection_impact_assessment_reference" =>
            setting.data_protection_impact_assessment_reference,
          "encrypted" => setting.encrypted?,
          "delete_after_seconds" => setting.delete_after&.to_i,
          "retain_until_rule" => setting.retain_until&.to_s,
          "retention_class_rule" => describe_rule(rule),
          "fail_capture_when_unavailable" => setting.fail_if_unavailable?
        }

        return entry unless category == :ip_geolocation

        entry.merge(
          "fields" => policy.request_evidence.enabled_ip_geolocation_fields,
          "resolver_named_by_policy" => policy.request_evidence.ip_geolocation_resolver_name&.to_s,
          "resolver" => describe_resolver(Clickwrap.config.ip_geolocation_resolver)
        )
      end

      def retention_inventory(retention_class)
        {
          "retention_class" => retention_class.key,
          "rules" => RetentionClass::PARTS.to_h do |part|
            [part.to_s, describe_rule(retention_class.rule_for(part))]
          end
        }
      end

      # A rule reads back as what it is: a fixed period, or the name of a host
      # calculation plus whether that calculation is currently registered. An
      # unregistered name is reported rather than smoothed over — it is the
      # difference between "not due yet" and "nothing can ever say when".
      def describe_rule(rule)
        return nil if rule.nil?
        return { "kind" => "duration", "seconds" => rule.duration.to_i } if rule.duration?

        {
          "kind" => "host_event",
          "host_event" => rule.host_event_name.to_s,
          "calculation_is_registered" => registered_host_events.include?(rule.host_event_name.to_sym)
        }
      end

      def unresolved_host_events
        names = Clickwrap.retention_classes.values.flat_map do |retention_class|
          RetentionClass::PARTS.filter_map do |part|
            rule = retention_class.rule_for(part)
            rule&.host_event? ? rule.host_event_name.to_sym : nil
          end
        end

        (names.uniq - registered_host_events).map(&:to_s).sort
      end

      def unresolved_host_events_for(policy, retention_class)
        from_policy = CATEGORIES.filter_map do |category|
          retain_until = policy.request_evidence.setting_for(category).retain_until
          retain_until&.to_sym
        end

        from_class = RetentionClass::PARTS.filter_map do |part|
          rule = retention_class&.rule_for(part)
          rule&.host_event? ? rule.host_event_name.to_sym : nil
        end

        ((from_policy + from_class).uniq - registered_host_events).map(&:to_s).sort
      end

      def registered_host_events = Clickwrap.config.retention_time_calculator_names

      def access_decisions
        config = Clickwrap.config

        {
          "authorize_receipt_access_with" => describe_callback(config.authorize_receipt_access_with),
          "authorize_unredacted_request_evidence_access_with" =>
            describe_callback(config.authorize_unredacted_request_evidence_access_with),
          "identify_actor_with" => describe_callback(config.identify_actor_with),
          "snapshot_actor_with" => describe_callback(config.snapshot_actor_with)
        }
      end

      # Where the decision lives, and whether it is still Clickwrap's own
      # declining default. A file and line number is the most useful thing an
      # inventory can say about a callback: it points at the code somebody has
      # to read to know what the application actually permits.
      def describe_callback(callable)
        location = callable.respond_to?(:source_location) ? callable.source_location : nil
        return { "defined_at" => "unknown" } if location.nil?

        {
          "defined_at" => location.join(":"),
          "is_clickwrap_default" => location.first.to_s.start_with?(GEM_LIB_ROOT)
        }
      end

      def describe_resolver(resolver)
        return { "configured" => false } if resolver.nil?

        { "configured" => true, "class" => resolver.class.name }
      end

      def plural_for(category)
        case category
        when :ip_address then "ip_addresses"
        when :browser_user_agent then "browser_user_agents"
        else "ip_geolocation"
        end
      end

      # --- Actor export and actor plans ----------------------------------------

      def current_statements_for(reference)
        StatementState.for_actor(reference).map do |state|
          {
            "policy" => state.policy_key,
            "statement" => state.statement_key,
            "kind" => state.kind,
            "state" => state.state,
            "effective_at" => Receipt.format_time(state.effective_at),
            "expires_at" => Receipt.format_time(state.expires_at)
          }.compact
        end
      end

      def actor_items(reference)
        holds = Retention::Planner::HoldIndex.load
        items = []

        Event.for_actor(reference).not_disposed.includes(:request_evidence).find_each do |event|
          held = holds.held?(event)
          items << actor_core_item(event, held)
          items.concat(actor_annex_items(event, held))
        end

        items
      end

      def actor_core_item(event, held)
        eligibility = Retention::Planner.core_event_eligibility(event)

        actor_item(part: :core_event, event: event, record_id: event.id, held: held,
                   eligibility: eligibility)
      end

      def actor_annex_items(event, held)
        annex = event.request_evidence
        return [] if annex.nil?

        CATEGORIES.filter_map do |category|
          next if annex.deleted_for?(category)
          next if annex.public_send(:"#{category}_recorded_at").nil?

          actor_item(part: category, event: event, record_id: annex.id, held: held,
                     eligibility: Retention::Planner.annex_eligibility(annex, category))
        end
      end

      # Every item carries the retention picture in its own detail line, so the
      # reviewer sees exactly what they would be overriding. Clickwrap states
      # the position; it does not resolve it.
      def actor_item(part:, event:, record_id:, held:, eligibility:)
        Retention::Planner::Item.new(
          part: part,
          status: held ? :held : :due,
          event_id: event.id,
          record_id: record_id,
          policy_key: event.policy_key,
          actor_reference: event.actor_reference,
          retention_class_key: event.retention_class_key,
          eligible_at: eligibility.eligible_at,
          rule: eligibility.rule,
          detail: actor_item_detail(held, eligibility),
          eligibility: "actor_request"
        )
      end

      def actor_item_detail(held, eligibility)
        return "Under a legal hold. Not included in this plan." if held
        return "Its retention rule cannot be resolved: #{eligibility.unresolved_reason}" if eligibility.unresolved?

        if eligibility.eligible_at > Clickwrap.now
          "Still inside its retention period, which ends #{Receipt.format_time(eligibility.eligible_at)}."
        else
          "Past its retention period, which ended #{Receipt.format_time(eligibility.eligible_at)}."
        end
      end

      def actor_summary(reference, due, held)
        {
          "generated_at" => Receipt.format_time(Clickwrap.now),
          "actor_reference" => reference,
          "due" => due.length,
          "held" => held.length,
          "still_within_retention_period" => due.count { |item| item.eligible_at && item.eligible_at > Clickwrap.now },
          "by_part" => due.group_by { |item| item.part.to_s }.transform_values(&:length),
          "held_examples" => held.first(Retention::Planner::EXAMPLE_LIMIT).map(&:to_plan_entry),
          "means" => "What exists for this actor, what is still inside its retention period, and " \
                     "what is under a legal hold. Applying this plan is a decision the host makes; " \
                     "Clickwrap does not decide whether an erasure request overrides a retention " \
                     "duty, a legal claim, or a hold."
        }
      end

      # --- Shared ---------------------------------------------------------------

      def reference_for(actor)
        Reference.actor(actor)
      end

      def reference_for!(actor)
        reference = reference_for(actor)
        return reference if reference.present?

        raise ArgumentError,
              "Clickwrap needs an actor, or the actor reference string recorded in the evidence " \
              "(for example \"gid://my-app/User/123\"). Evidence is keyed by that reference " \
              "precisely so it survives the account row being deleted."
      end

      def require_reason!(because)
        return unless because.to_s.strip.empty?

        raise LifecycleError,
              "Planning a disposition for an actor needs a `because:` naming the request it " \
              "answers. It is stored on the plan, and it is what tells the next reviewer why " \
              "somebody proposed deleting this."
      end
    end
  end
end
