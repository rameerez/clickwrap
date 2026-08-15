# frozen_string_literal: true

module Clickwrap
  # `bin/rails clickwrap:doctor` — a read-only diagnosis you can act on at 03:00.
  #
  #   ✓ 6 policies compiled
  #   ✓ all referenced documents are published and digest-verified
  #   ✓ every required gate has a remediation route
  #   ✓ request-derived personal data is off by default
  #   ! withdrawal_authorization records IP geolocation city without a review date
  #   ! request-source trust is unverified
  #   ✓ no overdue disposition
  #   ✓ all checked event digests verify
  #
  # ============================================================================
  # EVERY FINDING HERE IS AN OBJECTIVE FACT ABOUT CONFIGURATION OR DATA. This
  # class must never print, return, or imply "compliant", "court-proof", "audit
  # guaranteed", "approved", or "certified", and there is no overall verdict
  # line: a run with no warnings means the specific things listed below were
  # checked and nothing objectionable was found in them. It does not mean the
  # application is lawful, that its retention periods are right, or that its
  # evidence would persuade anyone. Those are not questions a library can
  # answer, and a green tick that implied otherwise would be worse than no tool
  # at all. PHRASES_THIS_REPORT_NEVER_PRINTS exists so a test can assert it.
  # ============================================================================
  class Doctor
    Finding = Data.define(:status, :message) do
      def ok? = status == :ok
      def warning? = status == :warning
      def problem? = status == :problem

      def to_s = "#{SYMBOLS.fetch(status, '?')} #{message}"
    end

    SYMBOLS = { ok: "✓", warning: "!", problem: "✗" }.freeze

    # Greped by the release test against every message this class produces.
    PHRASES_THIS_REPORT_NEVER_PRINTS = (
      Vocabulary::PROHIBITED_CLAIM_PHRASES + [
        "compliant",
        "compliance",
        "court proof",
        "audit guaranteed",
        "audit approved",
        "certified",
        "approved",
        "enforceable",
        "legally valid"
      ]
    ).freeze

    # How many recent events get their digests recomputed. A doctor run is
    # something an operator does interactively, so it samples rather than
    # verifying the whole table; `clickwrap:verify` is the exhaustive one.
    DIGEST_SAMPLE_SIZE = 100

    def report
      findings = []
      findings.concat(policy_findings)
      findings.concat(document_findings)
      findings.concat(gate_findings)
      findings.concat(request_evidence_findings)
      findings.concat(review_date_findings)
      findings.concat(resolver_findings)
      findings.concat(source_trust_findings)
      findings.concat(with_database("disposition") { disposition_findings })
      findings.concat(with_database("legal holds") { legal_hold_findings })
      findings.concat(with_database("event digests") { digest_findings })
      findings.concat(with_database("external actions") { external_action_findings })
      findings
    end

    # The README's rendering: one line per finding, in the order they were
    # produced, with nothing summarizing them into a verdict.
    def to_s = report.map(&:to_s).join("\n")

    private

    # --- Configuration --------------------------------------------------------

    def policy_findings
      count = Clickwrap.policies.size

      if count.zero?
        return [warning("no policies are compiled. Declare them with `Clickwrap.policy :key do ... end`, " \
                        "conventionally in config/clickwrap.rb.")]
      end

      [ok("#{count} #{pluralize(count, 'policy', 'policies')} compiled")]
    end

    # Every document a policy references has to exist, be published, and still
    # hash to what was recorded when it was published. A policy that presents a
    # document nobody published is a runtime failure waiting for the first
    # person who tries to sign up.
    def document_findings
      referenced = Clickwrap.policies.values.flat_map { |policy| policy.statements.flat_map(&:document_keys) }.uniq
      return [ok("no policy references a document")] if referenced.empty?

      problems = with_database("documents") { document_problems(referenced) }
      return problems if problems.any?

      [ok("all referenced documents are published and digest-verified " \
          "(#{referenced.length} #{pluralize(referenced.length, 'document', 'documents')})")]
    end

    def document_problems(referenced)
      referenced.flat_map do |key|
        definitions = Clickwrap.documents.values.select { |definition| definition.key == key }

        if definitions.empty?
          next [problem("document :#{key} is referenced by a policy but never declared with " \
                        "`Clickwrap.document :#{key}, version: \"...\", from: ...`")]
        end

        definitions.filter_map { |definition| document_problem(definition) }
      end
    end

    def document_problem(definition)
      document = Document.find_by(key: definition.key, tenant_key: definition.tenant_key)
      version = document&.versions&.find_by(version_label: definition.version_label, locale: definition.locale)

      if version.nil? || !version.published?
        return problem("document #{definition} is declared but not published. Run " \
                       "`bin/rails clickwrap:publish`.")
      end

      return nil if version.verify_content_digest

      problem("the stored bytes for document #{definition} no longer match the digest recorded " \
              "when it was published, so evidence citing it cannot be reproduced")
    end

    # A `requires_clickwrap` gate refuses to compile without somewhere to send
    # the person it stops, so the objective question left for the doctor is
    # whether the engine — the default destination — is actually mounted.
    def gate_findings
      return [ok("every required gate has a remediation route (Clickwrap::Engine is mounted)")] if engine_mounted?

      [warning("Clickwrap::Engine is not mounted, so every `requires_clickwrap` gate needs its own " \
               "`remediation_path:`. Mount it with `mount Clickwrap::Engine => \"/agreements\"` or " \
               "point each gate at a page you own.")]
    end

    def engine_mounted?
      ControllerHelpers.engine_is_mounted?
    rescue StandardError
      false
    end

    def request_evidence_findings
      config = Clickwrap.config

      if config.records_any_request_evidence_by_default?
        return [warning("request-derived personal data is recorded by default for every policy " \
                        "(#{default_categories.join(', ')}). That is a decision worth re-reading: " \
                        "a policy that does not need an IP address still gets one.")]
      end

      [ok("request-derived personal data is off by default")]
    end

    def default_categories
      config = Clickwrap.config
      categories = []
      categories << "ip_address" if config.record_ip_address_by_default
      categories << "browser_user_agent" if config.record_browser_user_agent_by_default
      geolocation = config.enabled_default_ip_geolocation_fields
      categories << "ip_geolocation #{geolocation.join('/')}" if geolocation.any?
      categories
    end

    # A policy that keeps a person's estimated city with no date on which
    # somebody looks at that decision again is how a temporary measure becomes
    # permanent. The date is the host's; the doctor only notices its absence.
    def review_date_findings
      Clickwrap.policies.values.filter_map do |policy|
        request_evidence = policy.request_evidence
        next unless request_evidence.records_ip_geolocation?

        review_on = request_evidence.review_configuration_on
        fields = request_evidence.enabled_ip_geolocation_fields.join(", ")

        if review_on.nil?
          warning("#{policy.key} records IP geolocation #{fields} without a review date. Add " \
                  "`review_request_evidence_configuration_on` so this decision gets looked at again.")
        elsif past?(review_on)
          warning("#{policy.key} was due to have its IP-geolocation configuration reviewed on " \
                  "#{review_on}, and that date has passed")
        end
      end + default_review_date_findings
    end

    def default_review_date_findings
      config = Clickwrap.config
      return [] unless config.records_any_request_evidence_by_default?

      review_on = config.review_default_request_evidence_configuration_on

      if review_on.nil?
        [warning("request evidence is recorded by default with no " \
                 "`review_default_request_evidence_configuration_on` date")]
      elsif past?(review_on)
        [warning("the default request-evidence configuration was due for review on #{review_on}, " \
                 "and that date has passed")]
      else
        []
      end
    end

    def resolver_findings
      configured = Clickwrap.config.ip_geolocation_resolver
      wanted = Clickwrap.policies.values.select { |policy| policy.request_evidence.records_ip_geolocation? }

      if configured.nil?
        return [ok("no IP-geolocation resolver is configured, and no policy asks for one")] if wanted.empty?

        # A warning rather than a problem: capture still succeeds and the field
        # is recorded as unavailable with a reason, which is the honest outcome.
        # What it is not is what the policy asked for, so somebody should know.
        return [warning("#{wanted.map(&:key).join(', ')} records IP geolocation but no " \
                        "`ip_geolocation_resolver` is configured, so every capture will record it " \
                        "as unavailable")]
      end

      [ok("an IP-geolocation resolver is configured (#{configured.class.name})")]
    end

    # An IP address read from a forwarded header is only as good as the proxy
    # configuration in front of it. Clickwrap cannot check a host's Cloudflare,
    # load balancer, or `config.hosts` setup; what it can check is whether the
    # host ever recorded that they verified one.
    def source_trust_findings
      records_ip_address = Clickwrap.config.record_ip_address_by_default ||
                           Clickwrap.policies.values.any? { |policy| policy.request_evidence.records_ip_address? }
      return [] unless records_ip_address

      if Clickwrap.config.trusted_proxy_configuration_digest.blank?
        return [warning("request-source trust is unverified: IP addresses are recorded, but no " \
                        "`trusted_proxy_configuration_digest` is set, so nothing records which " \
                        "proxy configuration (Cloudflare, a load balancer, a CDN) the addresses " \
                        "were read through")]
      end

      [ok("a reviewed trusted-proxy configuration digest is recorded with each recorded IP address")]
    end

    # --- Data -----------------------------------------------------------------

    def disposition_findings
      now = Clickwrap.now
      overdue = Event.due_for_core_disposition(now).count +
                RequestEvidence.with_ip_address_due(now).count +
                RequestEvidence.with_browser_user_agent_due(now).count +
                RequestEvidence.with_ip_geolocation_due(now).count

      return [ok("no overdue disposition")] if overdue.zero?

      [warning("#{overdue} #{pluralize(overdue, 'record is', 'records are')} past a retention rule " \
               "and still here. Run `bin/rails clickwrap:retention:plan`, review it, then " \
               "`bin/rails clickwrap:retention:apply PLAN=...`.")]
    end

    def legal_hold_findings
      in_effect = LegalHold.in_effect.count
      due = LegalHold.due_for_review(Clickwrap.now).count

      return [ok("no legal holds are in effect")] if in_effect.zero?

      if due.zero?
        return [ok("#{in_effect} legal #{pluralize(in_effect, 'hold', 'holds')} in effect, none past review")]
      end

      [warning("#{due} legal #{pluralize(due, 'hold is', 'holds are')} past the review date they " \
               "were placed with. A hold nobody revisits is how everything gets kept forever.")]
    end

    def digest_findings
      events = Event.order(id: :desc).limit(DIGEST_SAMPLE_SIZE).to_a
      return [ok("no events recorded yet")] if events.empty?

      failed = events.reject(&:digest_verified?)
      return [ok("all #{events.length} checked event digests verify")] if failed.empty?

      [problem("#{failed.length} of #{events.length} checked event digests do not match the bytes " \
               "they cover (first: #{failed.first.id}). That means those rows changed after they " \
               "were written; it does not on its own say who changed them.")]
    end

    def external_action_findings
      unresolved = ExternalAction.unresolved.count
      return [ok("no unresolved external actions")] if unresolved.zero?

      stale = ExternalAction.needing_reconciliation.count

      [warning("#{unresolved} external #{pluralize(unresolved, 'action is', 'actions are')} still " \
               "pending or unknown (#{stale} older than 15 minutes). Run " \
               "`bin/rails clickwrap:reconcile_external_actions` to list them.")]
    end

    # --- Plumbing -------------------------------------------------------------

    # Half of what the doctor checks needs the database, and the reason someone
    # is running it at 03:00 may well be that the database is unhappy. A failed
    # check reports what it could not read instead of taking the whole report
    # down with it.
    def with_database(what)
      yield
    rescue StandardError => e
      [warning("could not check #{what}: #{e.class}. #{e.message}")]
    end

    def past?(date)
      return false if date.nil?

      date.to_time <= Clickwrap.now
    rescue StandardError
      false
    end

    def pluralize(count, singular, plural) = count == 1 ? singular : plural

    def ok(message) = Finding.new(status: :ok, message: message)
    def warning(message) = Finding.new(status: :warning, message: message)
    def problem(message) = Finding.new(status: :problem, message: message)
  end
end
