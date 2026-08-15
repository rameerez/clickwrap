# frozen_string_literal: true

require "json"
require "time"

# The operator surface: everything you might need to run at 03:00, in one
# namespace, each task printing what it found in full sentences.
#
# Two rules hold across every task here.
#
# 1. NOTHING PRINTS A VERDICT. These tasks report configuration and data facts.
#    None of them says "compliant", "court-proof", or "audit guaranteed", and
#    none of them ever will — a task that printed a green verdict would be
#    making a legal determination on a host's behalf, which is the one thing
#    this gem exists not to do.
#
# 2. DESTRUCTIVE WORK IS TWO STEPS. `retention:plan` writes a plan and deletes
#    nothing. `retention:apply` requires that plan's id explicitly: there is no
#    `--all`, no `--yes`, and no way to apply "whatever is due right now"
#    without a human having looked at the list first.
module ClickwrapTasks
  module_function

  def say(text = "") = $stdout.puts(text)

  def heading(text)
    say
    say(text)
    say("=" * text.length)
  end

  def env(name)
    value = ENV.fetch(name, nil).to_s.strip
    value.empty? ? nil : value
  end

  def env!(name, usage)
    env(name) || abort("#{name} is required.\n\n  #{usage}\n")
  end

  def flag?(name) = %w[1 true yes on].include?(env(name).to_s.downcase)

  def json? = (env("FORMAT") || "").downcase == "json"

  def dump(object) = say(JSON.pretty_generate(object))

  def count(number, singular, plural = "#{singular}s")
    "#{number} #{number == 1 ? singular : plural}"
  end

  def list(entries)
    entries.each { |entry| say("  #{entry}") }
    say("  (none)") if entries.empty?
  end

  def remediation_route
    return "Clickwrap::Engine is mounted, so gated policies have a capture screen to redirect to" if
      Clickwrap::ControllerHelpers.engine_is_mounted?

    "Clickwrap::Engine is NOT mounted, so every requires_clickwrap gate needs its own remediation_path:"
  end

  # Who would be asked to act again if a newer required version were published:
  # the actors whose recorded evidence cites a document version that is no
  # longer the current one.
  #
  # Read row by row rather than in SQL. The recorded version ids live in a JSON
  # column, every adapter spells JSON containment differently, and an operator
  # preview is not the place to find that out.
  def reacceptance_report(policy, statement)
    current = statement.document_keys.to_h do |document_key|
      [document_key, Clickwrap::Document.find_by(key: document_key)&.current_version&.id&.to_s]
    end

    affected = Set.new
    total = 0

    states_for(policy, statement).find_each do |state|
      total += 1
      recorded = Array(state.document_version_ids).map(&:to_s)
      affected << state.actor_reference if current.values.compact.any? { |id| !recorded.include?(id) }
    end

    say("  #{statement.key} (#{statement.kind})")
    current.each { |key, id| say("    current published version of #{key}: #{id || "(nothing published)"}") }
    say("    actors with current evidence:    #{total}")
    say("    actors who would be asked again: #{affected.size}")
  end

  def states_for(policy, statement)
    Clickwrap::StatementState.for_policy(policy.key).for_statement(statement.key).active
  end

  # Recomputes event digests. Whole table by default; SINCE and LIMIT narrow it,
  # because "verify everything" and "verify what happened since last night" are
  # both things an operator legitimately wants at 03:00.
  def digest_sweep
    checked = 0
    failed = []

    check = lambda do |event|
      checked += 1
      failed << event.id unless event.digest_verified?
    end

    events = sweep_scope
    events.respond_to?(:find_each) ? events.find_each(&check) : events.each(&check)

    { "checked" => checked, "verified" => checked - failed.length, "failed" => failed }
  end

  def sweep_scope
    scope = Clickwrap::Event.all
    since = env("SINCE")
    scope = scope.where(recorded_at_by_server: Time.parse(since)..) if since
    limit = env("LIMIT")

    limit ? scope.order(id: :desc).limit(limit.to_i).to_a : scope
  end
end

namespace :clickwrap do
  desc "Report objective configuration and data facts about this installation"
  task doctor: :environment do
    findings = Clickwrap::Doctor.new.report

    if ClickwrapTasks.json?
      ClickwrapTasks.dump(findings.map { |f| { "status" => f.status.to_s, "message" => f.message } })
    else
      findings.each { |finding| ClickwrapTasks.say(finding.to_s) }
    end

    # An objective failure — a document whose bytes no longer match, a digest
    # that does not recompute — exits non-zero so a monitor notices. That is a
    # statement about this installation's data, not about anybody's legal
    # position.
    exit(1) if findings.any?(&:problem?)
  end

  desc "Publish every declared document version that has not been published yet"
  task publish: :environment do
    outcomes = Clickwrap.publish!

    ClickwrapTasks.heading("Publishing documents")
    outcomes.each { |outcome| ClickwrapTasks.say("  #{outcome.status}: #{outcome.definition} — #{outcome.message}") }
    ClickwrapTasks.say
    ClickwrapTasks.say("#{ClickwrapTasks.count(outcomes.count(&:published?), "document")} published, " \
                       "#{outcomes.count(&:unchanged?)} already published with identical bytes.")
  end

  namespace :publish do
    desc "Show what clickwrap:publish would do, without writing anything"
    task plan: :environment do
      outcomes = Clickwrap.publish!(dry_run: true)

      ClickwrapTasks.heading("Publishing plan (nothing was written)")
      outcomes.each do |outcome|
        ClickwrapTasks.say("  #{outcome.status}: #{outcome.definition} — #{outcome.message}")
      end
    end
  end

  namespace :reacceptance do
    desc "Preview who a newly published version would require to act again (POLICY=key)"
    task plan: :environment do
      key = ClickwrapTasks.env!("POLICY", "bin/rails clickwrap:reacceptance:plan POLICY=current_terms")
      policy = Clickwrap.policy!(key)
      statements = policy.statements.select(&:requires_current_version?)

      ClickwrapTasks.heading("Reacceptance plan for #{policy.key}")

      if statements.empty?
        ClickwrapTasks.say("  No statement in this policy declares `require_current_version: true`, so")
        ClickwrapTasks.say("  publishing a new document version does not require anyone to act again.")
      else
        statements.each { |statement| ClickwrapTasks.reacceptance_report(policy, statement) }
      end

      ClickwrapTasks.say
      ClickwrapTasks.say("Remediation route: #{ClickwrapTasks.remediation_route}")
      ClickwrapTasks.say("Nothing was emailed, nothing changed, and Clickwrap does not decide whether")
      ClickwrapTasks.say("this change is material. That is the application's call.")
    end
  end

  desc "Verify recorded evidence: one event with EVENT_ID, or the whole chain and digests"
  task verify: :environment do
    event_id = ClickwrapTasks.env("EVENT_ID")

    if event_id
      event = Clickwrap::Event.find_by(id: event_id) || abort("No Clickwrap event with id #{event_id}.")
      result = Clickwrap.verify(event.id)
      report = {
        "event_id" => event.id,
        "event_type" => event.event_type,
        "policy" => event.policy_key,
        "digest_verifies" => event.digest_verified?,
        "verification" => result.to_h
      }

      if ClickwrapTasks.json?
        ClickwrapTasks.dump(report)
      else
        ClickwrapTasks.heading("Event #{event.id}")
        ClickwrapTasks.say("  policy:            #{event.policy_key} (#{event.event_type})")
        ClickwrapTasks.say("  recorded by server: #{event.recorded_at_by_server}")
        ClickwrapTasks.say("  digest verifies:   #{event.digest_verified?}")
        ClickwrapTasks.say("  verification:      #{result.success? ? "satisfied" : result.error}")
      end

      exit(1) unless event.digest_verified?
    else
      chain = Clickwrap::Integrity::Chain.verify
      digests = ClickwrapTasks.digest_sweep

      if ClickwrapTasks.json?
        ClickwrapTasks.dump("chain" => chain.to_h, "digests" => digests)
      else
        ClickwrapTasks.heading("Chain verification")
        ClickwrapTasks.say("  chaining enabled:  #{chain.chaining_enabled}")
        ClickwrapTasks.say("  scopes walked:     #{chain.scopes.length}")
        ClickwrapTasks.say("  events checked:    #{chain.checked}")
        ClickwrapTasks.say("  first break:       #{chain.first_break || "none"}")
        ClickwrapTasks.say
        ClickwrapTasks.heading("Event digests")
        ClickwrapTasks.say("  events checked:    #{digests["checked"]}")
        ClickwrapTasks.say("  digests verifying: #{digests["verified"]}")
        ClickwrapTasks.say("  not verifying:     #{digests["failed"].length}")
        ClickwrapTasks.list(digests["failed"].first(20))
        ClickwrapTasks.say
        ClickwrapTasks.say("A verifying digest detects accidental or ordinary modification of the bytes it")
        ClickwrapTasks.say("covers. It does not establish who produced them or when.")
      end

      exit(1) unless chain.success? && digests["failed"].empty?
    end
  end

  desc "Print one receipt as canonical JSON (EVENT_ID=..., sensitive fields opt in by name)"
  task export: :environment do
    event_id = ClickwrapTasks.env!("EVENT_ID", "bin/rails clickwrap:export EVENT_ID=01K2Y8T5QY0N4V6N1H4G4CQY8J")
    receipt = Clickwrap.receipt(event_id)

    ClickwrapTasks.dump(
      Clickwrap.export_receipt(
        receipt,
        requested_by: ClickwrapTasks.env("REQUESTED_BY"),
        because: ClickwrapTasks.env("BECAUSE"),
        include_ip_address: ClickwrapTasks.flag?("INCLUDE_IP_ADDRESS"),
        include_browser_user_agent: ClickwrapTasks.flag?("INCLUDE_BROWSER_USER_AGENT"),
        include_ip_geolocation: ClickwrapTasks.flag?("INCLUDE_IP_GEOLOCATION")
      )
    )
  end

  namespace :retention do
    desc "Build a reviewable disposition plan. Deletes nothing."
    task plan: :environment do
      plan = Clickwrap::Retention::Planner.new(
        policy_key: ClickwrapTasks.env("POLICY"),
        actor_reference: ClickwrapTasks.env("ACTOR"),
        created_by: ClickwrapTasks.env("BY"),
        because: ClickwrapTasks.env("BECAUSE")
      ).call

      summary = plan.summary.to_h

      if ClickwrapTasks.json?
        ClickwrapTasks.dump("plan_id" => plan.id, "expires_at" => plan.expires_at.to_s, "summary" => summary)
      else
        ClickwrapTasks.heading("Disposition plan #{plan.id}")
        ClickwrapTasks.say("  due:        #{summary["due"]}")
        ClickwrapTasks.say("  held:       #{summary["held"]} (a legal hold is pausing these)")
        ClickwrapTasks.say("  unresolved: #{summary["unresolved"]} (a host event has not happened yet)")
        ClickwrapTasks.say
        ClickwrapTasks.say("  by part:")
        summary["by_part"].each { |part, counts| ClickwrapTasks.say("    #{part}: #{counts.inspect}") }
        ClickwrapTasks.say("  by policy:")
        summary["by_policy"].each { |policy, counts| ClickwrapTasks.say("    #{policy}: #{counts.inspect}") }
        ClickwrapTasks.say
        ClickwrapTasks.say("Nothing has been deleted. Review the plan, then:")
        ClickwrapTasks.say("  bin/rails clickwrap:retention:apply PLAN=#{plan.id}")
        ClickwrapTasks.say("The plan expires at #{plan.expires_at}, and is re-checked item by item when applied.")
      end
    end

    desc "Apply one reviewed disposition plan (PLAN=id). Deletes evidence."
    task apply: :environment do
      plan_id = ClickwrapTasks.env!(
        "PLAN",
        "bin/rails clickwrap:retention:apply PLAN=01K2Y8T5QY0N4V6N1H4G4CQY8J  (run clickwrap:retention:plan first)"
      )

      plan = Clickwrap::DispositionPlan.find_by(id: plan_id) || abort("No disposition plan with id #{plan_id}.")
      result = Clickwrap::Retention::Applier.new(plan, applied_by: ClickwrapTasks.env("BY")).call

      if ClickwrapTasks.json?
        ClickwrapTasks.dump(result.to_h)
      else
        ClickwrapTasks.heading("Applied disposition plan #{plan.id}")
        result.counts.each { |name, number| ClickwrapTasks.say("  #{name.ljust(16)} #{number}") }
        ClickwrapTasks.say
        ClickwrapTasks.say("  skipped because a legal hold is in effect:")
        ClickwrapTasks.list(result.skipped_held.first(20).map { |o| "#{o.part} #{o.event_id}: #{o.note}" })
        ClickwrapTasks.say("  skipped because something changed since the plan was reviewed:")
        ClickwrapTasks.list(result.skipped_changed.first(20).map { |o| "#{o.part} #{o.event_id}: #{o.note}" })
        ClickwrapTasks.say("  errors:")
        ClickwrapTasks.list(result.errors.first(20).map { |o| "#{o.part} #{o.event_id}: #{o.note}" })
      end

      exit(1) unless result.clean?
    end
  end

  namespace :holds do
    desc "List legal holds in effect and the ones past their review date"
    task review: :environment do
      now = Clickwrap.now
      in_effect = Clickwrap::LegalHold.in_effect.order(:review_on).to_a
      due = in_effect.select { |hold| hold.review_on <= now }

      ClickwrapTasks.heading("Legal holds")
      ClickwrapTasks.say("  in effect:        #{in_effect.length}")
      ClickwrapTasks.say("  past review date: #{due.length}")
      ClickwrapTasks.say
      ClickwrapTasks.say("  past their review date:")
      ClickwrapTasks.list(
        due.map do |hold|
          "#{hold.scope} #{hold.event_id || hold.actor_reference || hold.policy_key} — " \
            "review due #{hold.review_on}, placed #{hold.placed_at} by #{hold.placed_by_reference}: #{hold.reason}"
        end
      )
      ClickwrapTasks.say
      ClickwrapTasks.say("A hold pauses scheduled disposition. One nobody revisits is how everything")
      ClickwrapTasks.say("ends up kept forever, which is why every hold carries a review date and an owner.")
    end
  end

  namespace :privacy do
    desc "Describe what this application is configured to record, and why it says it does"
    task inventory: :environment do
      inventory = Clickwrap::Privacy.inventory

      if ClickwrapTasks.json?
        ClickwrapTasks.dump(inventory)
      else
        ClickwrapTasks.heading("Request-evidence inventory")
        ClickwrapTasks.say("  records anything by default: " \
                           "#{inventory["defaults"]["records_any_request_evidence_by_default"]}")
        ClickwrapTasks.say("  unresolved host events:      " \
                           "#{inventory["unresolved_host_events"].join(", ").presence || "(none)"}")

        recording, quiet = inventory["policies"].partition { |policy| policy["records_any_request_evidence"] }

        ClickwrapTasks.say("  policies recording no request evidence: " \
                           "#{quiet.map { |policy| policy["policy"] }.join(", ").presence || "(none)"}")

        recording.each do |policy|
          ClickwrapTasks.say
          ClickwrapTasks.say("  #{policy["policy"]} (retention class #{policy["retention_class"]})")
          policy["fields"].each do |field, details|
            next unless details["recorded"]

            ClickwrapTasks.say("    #{field}: #{details["because"]}")
            ClickwrapTasks.say("      legal basis reference: " \
                               "#{details["legal_basis_reference"] || "(none supplied)"}")
            ClickwrapTasks.say("      encrypted: #{details["encrypted"]}, " \
                               "delete after: #{details["delete_after_seconds"] || details["retain_until_rule"]}")
            ClickwrapTasks.say("      fields: #{details["fields"].join(", ")}") if details["fields"]
          end
          ClickwrapTasks.say("    review on: " \
                             "#{policy["review_request_evidence_configuration_on"] || "(no date set)"}")
        end

        ClickwrapTasks.say
        ClickwrapTasks.say("This describes a configuration. Describing a configuration is not the same as")
        ClickwrapTasks.say("the configuration being lawful, necessary, or proportionate.")
      end
    end

    desc "Export every receipt recorded for one actor (ACTOR=gid://my-app/User/123)"
    task export: :environment do
      actor = ClickwrapTasks.env!("ACTOR", "bin/rails clickwrap:privacy:export ACTOR=gid://my-app/User/123")

      ClickwrapTasks.dump(
        Clickwrap::Privacy.export_for(
          actor,
          requested_by: ClickwrapTasks.env("REQUESTED_BY"),
          because: ClickwrapTasks.env("BECAUSE"),
          include_ip_address: ClickwrapTasks.flag?("INCLUDE_IP_ADDRESS"),
          include_browser_user_agent: ClickwrapTasks.flag?("INCLUDE_BROWSER_USER_AGENT"),
          include_ip_geolocation: ClickwrapTasks.flag?("INCLUDE_IP_GEOLOCATION")
        )
      )
    end

    namespace :disposition do
      desc "Build a reviewable plan for one actor's evidence (ACTOR=gid://...). Deletes nothing."
      task plan: :environment do
        actor = ClickwrapTasks.env!(
          "ACTOR",
          "bin/rails clickwrap:privacy:disposition:plan ACTOR=gid://my-app/User/123 BECAUSE=\"DSAR-2026-41\""
        )
        because = ClickwrapTasks.env!("BECAUSE", "BECAUSE=\"Verified erasure request DSAR-2026-41\"")

        plan = Clickwrap::Privacy.plan_disposition_for(
          actor,
          requested_by: ClickwrapTasks.env("BY"),
          because: because
        )
        summary = plan.summary.to_h

        ClickwrapTasks.heading("Actor disposition plan #{plan.id}")
        ClickwrapTasks.say("  items:                         #{summary["due"]}")
        ClickwrapTasks.say("  held by a legal hold:          #{summary["held"]}")
        ClickwrapTasks.say("  still within retention period: #{summary["still_within_retention_period"]}")
        ClickwrapTasks.say("  by part: #{summary["by_part"].inspect}")
        ClickwrapTasks.say
        ClickwrapTasks.say("Nothing has been deleted. This plan does not decide whether an erasure request")
        ClickwrapTasks.say("overrides a retention duty, a legal claim, or a hold — it shows what exists so")
        ClickwrapTasks.say("the person who makes that decision can see it.")
      end
    end
  end

  desc "List external actions that are still pending or unknown"
  task reconcile_external_actions: :environment do
    unresolved = Clickwrap::ExternalAction.unresolved.order(:requested_at).to_a
    stale = Clickwrap::ExternalAction.needing_reconciliation.count

    ClickwrapTasks.heading("Unresolved external actions")
    ClickwrapTasks.say("  pending or unknown: #{unresolved.length}")
    ClickwrapTasks.say("  older than 15 minutes: #{stale}")
    ClickwrapTasks.say
    ClickwrapTasks.list(
      unresolved.first(50).map do |action|
        "#{action.state} #{action.policy_key} #{action.idempotency_key} " \
          "(requested #{action.requested_at}, #{action.attempts} attempts) provider=#{action.provider_name}"
      end
    )
    ClickwrapTasks.say
    ClickwrapTasks.say("Clickwrap will not guess an outcome for any of these. `unknown` means the request")
    ClickwrapTasks.say("may or may not have been carried out, and treating that as a failure is how a")
    ClickwrapTasks.say("second debit happens. Ask the provider, then record what it says:")
    ClickwrapTasks.say("  action.record_provider_success_and_consume!(receipt)")
    ClickwrapTasks.say("  action.record_provider_failure!(reason: \"...\")")
    ClickwrapTasks.say("  action.record_provider_outcome_unknown!(reason: \"...\")")
  end
end

namespace :clickwrap do
  namespace :import do
    namespace :fine_print do
      desc "Preview what a FinePrint import would record, without writing anything"
      task plan: :environment do
        report = Clickwrap::Import::FinePrint.plan

        ClickwrapTasks.heading("FinePrint import plan")
        ClickwrapTasks.say(report.respond_to?(:message) ? report.message : report.to_s)
        ClickwrapTasks.say
        ClickwrapTasks.say("Nothing has been written. Fields FinePrint never recorded — the presentation")
        ClickwrapTasks.say("manifest, the IP address, the call to action, the protected action — stay")
        ClickwrapTasks.say("unknown in the imported events. Historical weakness stays visible rather than")
        ClickwrapTasks.say("being laundered into modern certainty.")
      end
    end

    desc "Import FinePrint contract versions and signatures as imported_legacy events"
    task fine_print: :environment do
      report = Clickwrap::Import::FinePrint.import!

      ClickwrapTasks.heading("FinePrint import")
      ClickwrapTasks.say(report.respond_to?(:message) ? report.message : report.to_s)
    end
  end
end
