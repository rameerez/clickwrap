# frozen_string_literal: true

module Clickwrap
  module Retention
    # Builds a reviewable disposition plan. Deletes nothing.
    #
    #   plan = Clickwrap::Retention::Planner.new(created_by: current_operator).call
    #   plan.summary   # => counts by policy, by part, plus held and unresolved
    #   plan.id        # => the id `clickwrap:retention:apply PLAN=...` needs
    #
    # Disposition is always two steps here: plan, review, then apply. This is
    # the first step, and it is deliberately read-only — an operator can run it
    # on a Friday afternoon without consequence, and the numbers it reports are
    # the numbers the applier will re-derive.
    #
    # Three properties of the report matter more than the totals:
    #
    #   * Held records are counted SEPARATELY rather than silently dropped, so
    #     an operator who expected 4,000 items and sees 12 can tell that a legal
    #     hold is working rather than that the query is broken.
    #
    #   * A host-event rule that resolves to nil is UNRESOLVED, never due. "Five
    #     years, or three years after this contract is liquidated, whichever is
    #     later" has not started its clock until liquidation happens, and a job
    #     that treats "we cannot say yet" as "delete it now" destroys regulated
    #     evidence early. That failure mode is specific, foreseeable, and the
    #     reason this class reports a third category instead of two.
    #
    #   * Nothing here decides a retention period. The host and its counsel
    #     chose the rules; this reads them back and says what they currently
    #     imply.
    class Planner
      KIND = "retention"

      # Parts of the evidence a plan can cover. The first four are the parts of
      # an event, named exactly as the retention DSL names them; the fifth is a
      # persisted presentation, which is not evidence of an act and ages out on
      # its own schedule.
      PARTS = (RetentionClass::PARTS + %i[presentation]).freeze
      ANNEX_PARTS = %i[ip_address browser_user_agent ip_geolocation].freeze

      # How many held and unresolved examples travel in the summary. The counts
      # are always complete; the examples exist so an operator can see what kind
      # of thing is being held without opening a console, and are capped so a
      # plan row stays a plan row rather than a data export.
      EXAMPLE_LIMIT = 25

      # What a rule currently says about one part, with "we cannot say yet"
      # kept as a first-class answer rather than folded into a date.
      Eligibility = Data.define(:eligible_at, :rule, :unresolved_reason) do
        def initialize(eligible_at: nil, rule: nil, unresolved_reason: nil)
          super
        end

        def resolved? = !eligible_at.nil?
        def unresolved? = eligible_at.nil?
        def due?(at) = resolved? && eligible_at <= at
      end

      # One line of a plan. `eligibility` records which question the applier
      # must re-ask: a retention plan re-checks whether the rule still says the
      # item is due, while an actor-request plan re-checks that the item still
      # exists and is not held, because whether an erasure request outranks a
      # retention duty is a decision a human made, not one this gem can make.
      Item = Data.define(:part, :status, :event_id, :record_id, :policy_key, :actor_reference,
                         :retention_class_key, :eligible_at, :rule, :detail, :eligibility) do
        def initialize(part:, status:, event_id: nil, record_id: nil, policy_key: nil,
                       actor_reference: nil, retention_class_key: nil, eligible_at: nil,
                       rule: nil, detail: nil, eligibility: "retention")
          super
        end

        def to_plan_entry
          {
            "part" => part.to_s,
            "status" => status.to_s,
            "event_id" => event_id,
            "record_id" => record_id&.to_s,
            "policy_key" => policy_key,
            "actor_reference" => actor_reference,
            "retention_class" => retention_class_key,
            "eligible_at" => eligible_at && Receipt.format_time(eligible_at),
            "rule" => rule,
            "detail" => detail,
            "eligibility" => eligibility
          }.compact
        end

        def self.from_plan_entry(entry)
          entry = entry.to_h
          new(
            part: entry["part"].to_s.to_sym,
            status: entry["status"].to_s.to_sym,
            event_id: entry["event_id"],
            record_id: entry["record_id"],
            policy_key: entry["policy_key"],
            actor_reference: entry["actor_reference"],
            retention_class_key: entry["retention_class"],
            rule: entry["rule"],
            detail: entry["detail"],
            eligibility: entry["eligibility"] || "retention"
          )
        end
      end

      class << self
        # What the core event's rule currently says. Shared with the applier so
        # planning and applying can never disagree about what "due" means.
        #
        # The order matters. A schedule computed at capture (`retain_core_event_until`)
        # wins, because that is what the receipt already told the world. Only
        # when there is none does this fall back to the rule the class names
        # today — which is also how a lifecycle event appended after the fact,
        # with no schedule of its own, ages out with the capture it belongs to.
        def core_event_eligibility(event)
          return Eligibility.new(eligible_at: event.retain_core_event_until, rule: "recorded_schedule") if
            event.retain_core_event_until.present?

          return resolve_host_event(event.retention_rule_name, event) if event.retention_rule_name.present?

          retention_class = Clickwrap.retention_classes[event.retention_class_key.to_s]

          if retention_class.nil?
            return Eligibility.new(
              rule: "retention_class:#{event.retention_class_key}",
              unresolved_reason: "Retention class #{event.retention_class_key.inspect} is no longer " \
                                 "defined, so nothing can say when this event is due."
            )
          end

          rule = retention_class.rule_for(:core_event)
          return Eligibility.new(rule: nil, unresolved_reason: "No core-event rule is defined.") if rule.nil?
          return resolve_host_event(rule.host_event_name, event) if rule.host_event?

          Eligibility.new(eligible_at: event.recorded_at_by_server + rule.duration,
                          rule: "duration:#{rule.duration.to_i}s")
        end

        # What one annex field's rule currently says. The row carries its own
        # schedule or its own named rule, recorded when the value was captured,
        # so this reads the row rather than today's policy: the person whose IP
        # address it is was told the period that applied then.
        def annex_eligibility(annex, part)
          delete_after = annex.public_send(:"#{part}_delete_after")
          return Eligibility.new(eligible_at: delete_after, rule: "recorded_schedule") if delete_after.present?

          rule_name = annex.public_send(:"#{part}_retain_until_rule")
          return resolve_host_event(rule_name, annex.event) if rule_name.present?

          Eligibility.new(
            rule: nil,
            unresolved_reason: "No deletion rule is recorded for #{part} on this row."
          )
        end

        # A host calculation may legitimately return nil ("the triggering event
        # has not happened"), may be unregistered, and may raise — a retention
        # calculation runs the host's own domain code. All three are reported as
        # unresolved with the reason attached, because a disposition run that
        # crashes on one row, or that guesses a date to keep going, is worse
        # than one that says which rows it could not evaluate.
        def resolve_host_event(name, event)
          return Eligibility.new(rule: nil, unresolved_reason: "No rule name recorded.") if name.blank?

          rule = "host_event:#{name}"
          resolved = Clickwrap.configuration.resolve_retention_time(name, event)

          if resolved.nil?
            return Eligibility.new(
              rule: rule,
              unresolved_reason: "The host calculation #{name} has not resolved yet, so the " \
                                 "triggering event has not happened and the clock has not started."
            )
          end

          Eligibility.new(eligible_at: resolved, rule: rule)
        rescue StandardError => error
          Eligibility.new(
            rule: "host_event:#{name}",
            unresolved_reason: "The host calculation #{name} could not be evaluated (#{error.class})."
          )
        end
      end

      def initialize(at: Clickwrap.now, policy_key: nil, actor_reference: nil, created_by: nil, because: nil)
        @at = at
        @policy_key = policy_key&.to_s
        @actor_reference = reference_for(actor_reference)
        @created_by = created_by
        @because = because
        @items = []
      end

      attr_reader :at, :policy_key, :actor_reference, :created_by, :because, :items

      # Builds and persists the plan. Nothing is deleted, nothing is marked, and
      # no state changes anywhere else.
      def call
        @items = []

        plan_core_events
        plan_request_evidence
        plan_presentations

        DispositionPlan.create!(
          kind: KIND,
          scope: scope_document,
          summary: summary_document,
          item_count: due_items.length,
          created_by_reference: reference_for(created_by),
          reason: because
        )
      end

      def due_items = items.select { |item| item.status == :due }
      def held_items = items.select { |item| item.status == :held }
      def unresolved_items = items.select { |item| item.status == :unresolved }

      private

      # --- The core event -------------------------------------------------------

      # Three queries rather than one scan of the table.
      #
      # The first uses the schedule written at capture, which is indexed. The
      # second catches rows that never got one — an appended lifecycle event has
      # its class but no computed date — by pushing the class's duration into
      # the WHERE clause instead of loading every event to subtract in Ruby. The
      # third is the only unavoidable scan, and it is bounded to the classes
      # that actually use a host-event rule, because those are precisely the
      # rows whose answer cannot be computed in SQL.
      def plan_core_events
        seen = Set.new

        core_event_scopes.each do |scope|
          scope.find_each do |event|
            next unless seen.add?(event.id)

            record_core_event(event)
          end
        end
      end

      def core_event_scopes
        scopes = [base_events.where.not(retain_core_event_until: nil).where(retain_core_event_until: ...at)]

        Clickwrap.retention_classes.each do |retention_class|
          rule = retention_class.rule_for(:core_event)
          next if rule.nil?

          unscheduled = base_events.where(retain_core_event_until: nil, retention_class_key: retention_class.key)

          scopes << if rule.duration?
                      unscheduled.where(recorded_at_by_server: ...(at - rule.duration))
                    else
                      unscheduled
                    end
        end

        scopes << base_events.where(retain_core_event_until: nil).where.not(retention_rule_name: nil)
        scopes
      end

      def record_core_event(event)
        eligibility = self.class.core_event_eligibility(event)
        return if eligibility.resolved? && !eligibility.due?(at)

        record(
          part: :core_event,
          status: status_for(eligibility, held: hold_index.held?(event)),
          event: event,
          record_id: event.id,
          eligibility: eligibility
        )
      end

      # --- The optional request-evidence annex ----------------------------------

      def plan_request_evidence
        ANNEX_PARTS.each do |part|
          seen = Set.new

          annex_scopes(part).each do |scope|
            scope.find_each do |annex|
              next unless seen.add?(annex.id)
              next if annex.event.nil?

              record_annex_field(annex, part)
            end
          end
        end
      end

      def annex_scopes(part)
        [
          base_annexes.public_send(:"with_#{part}_due", at),
          base_annexes.where("#{part}_deleted_at": nil, "#{part}_delete_after": nil)
                      .where.not("#{part}_retain_until_rule": nil)
        ]
      end

      def record_annex_field(annex, part)
        eligibility = self.class.annex_eligibility(annex, part)
        return if eligibility.resolved? && !eligibility.due?(at)

        record(
          part: part,
          status: status_for(eligibility, held: hold_index.held?(annex.event)),
          event: annex.event,
          record_id: annex.id,
          eligibility: eligibility
        )
      end

      # --- Persisted presentations ---------------------------------------------

      # A presentation row is not evidence of an act: it is the manifest the
      # server offered. The one attached to a capture belongs to that event and
      # is never touched here — `where.missing(:events)` is what keeps a
      # retention run from deleting the manifest a receipt cites. What is left
      # is the pre-submit rows a policy chose to retain, and expired offers
      # nobody ever submitted.
      def plan_presentations
        seen = Set.new

        presentation_scopes.each do |scope|
          scope.where.missing(:events).find_each do |presentation|
            next unless seen.add?(presentation.id)

            record(
              part: :presentation,
              status: :due,
              event: nil,
              record_id: presentation.id,
              policy_key_override: presentation.policy_key,
              actor_reference_override: presentation.actor_reference,
              eligibility: Eligibility.new(
                eligible_at: presentation.retain_until || presentation.expires_at,
                rule: presentation.retain_until ? "recorded_schedule" : "presentation_expiry"
              )
            )
          end
        end
      end

      def presentation_scopes
        scope = Presentation.all
        scope = scope.where(policy_key: policy_key) if policy_key
        scope = scope.where(actor_reference: actor_reference) if actor_reference

        [
          scope.due_for_disposition(at),
          scope.pending.where(retain_until: nil).expired_at(at)
        ]
      end

      # --- Assembling the plan --------------------------------------------------

      def base_events
        scope = Event.not_disposed
        scope = scope.for_policy(policy_key) if policy_key
        scope = scope.for_actor(actor_reference) if actor_reference
        scope
      end

      # `preload` rather than `includes`, because this relation also joins the
      # same table to filter on it, and a single query doing both would have to
      # disambiguate the alias. Two queries and no ambiguity is the better
      # trade for a batch job.
      def base_annexes
        scope = RequestEvidence.preload(:event).joins(:event)
        scope = scope.where(clickwrap_events: { policy_key: policy_key }) if policy_key
        scope = scope.where(clickwrap_events: { actor_reference: actor_reference }) if actor_reference
        scope
      end

      def hold_index
        @hold_index ||= HoldIndex.load
      end

      def status_for(eligibility, held:)
        return :unresolved if eligibility.unresolved?
        return :held if held

        :due
      end

      def record(part:, status:, event:, record_id:, eligibility:,
                 policy_key_override: nil, actor_reference_override: nil)
        @items << Item.new(
          part: part,
          status: status,
          event_id: event&.id,
          record_id: record_id,
          policy_key: policy_key_override || event&.policy_key,
          actor_reference: actor_reference_override || event&.actor_reference,
          retention_class_key: event&.retention_class_key,
          eligible_at: eligibility.eligible_at,
          rule: eligibility.rule,
          detail: eligibility.unresolved_reason
        )
      end

      # The exact set an operator reviewed. The applier reads `items` back and
      # re-checks every one of them; the plan is the record of what was agreed
      # to, not an instruction the applier follows blindly.
      def scope_document
        {
          "kind" => KIND,
          "at" => Receipt.format_time(at),
          "policy_key" => policy_key,
          "actor_reference" => actor_reference,
          "items" => due_items.map(&:to_plan_entry)
        }.compact
      end

      def summary_document
        {
          "generated_at" => Receipt.format_time(Clickwrap.now),
          "evaluated_at" => Receipt.format_time(at),
          "due" => due_items.length,
          "held" => held_items.length,
          "unresolved" => unresolved_items.length,
          "by_part" => counts_by(&:part),
          "by_policy" => counts_by { |item| item.policy_key || "(none)" },
          "held_examples" => held_items.first(EXAMPLE_LIMIT).map(&:to_plan_entry),
          "unresolved_examples" => unresolved_items.first(EXAMPLE_LIMIT).map(&:to_plan_entry),
          "means" => "What each rule currently says is due, held, or not yet resolvable. Nothing " \
                     "has been deleted, and Clickwrap did not choose any of these periods."
        }
      end

      # Counts are always broken out three ways, and a zero is printed rather
      # than omitted: "0 held" and "held is missing from the report" are
      # different statements, and only one of them is reassuring.
      def counts_by
        items.group_by { |item| yield(item).to_s }.transform_values do |group|
          {
            "due" => group.count { |item| item.status == :due },
            "held" => group.count { |item| item.status == :held },
            "unresolved" => group.count { |item| item.status == :unresolved }
          }
        end
      end

      def reference_for(actor)
        return nil if actor.nil?
        return actor if actor.is_a?(String)

        Clickwrap.config.identify_actor_with.call(actor)
      end

      # Every legal hold currently in effect, loaded once.
      #
      # Holds are few and disposition runs touch many rows, so the alternative —
      # three existence queries per candidate — would make the safety check the
      # expensive part of the job, and an expensive safety check is one someone
      # eventually turns off.
      class HoldIndex
        def self.load
          holds = LegalHold.in_effect.to_a

          new(
            event_ids: holds.select { |hold| hold.scope == "event" }.map(&:event_id).compact.to_set,
            actor_references: holds.select { |hold| hold.scope == "actor" }.map(&:actor_reference).compact.to_set,
            policy_keys: holds.select { |hold| hold.scope == "policy" }.map(&:policy_key).compact.to_set
          )
        end

        def initialize(event_ids:, actor_references:, policy_keys:)
          @event_ids = event_ids
          @actor_references = actor_references
          @policy_keys = policy_keys
        end

        def held?(event)
          return false if event.nil?

          event.on_legal_hold? ||
            @event_ids.include?(event.id) ||
            @actor_references.include?(event.actor_reference) ||
            @policy_keys.include?(event.policy_key)
        end
      end
    end
  end
end
