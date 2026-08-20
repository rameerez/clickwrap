# frozen_string_literal: true

require "test_helper"

# `bin/rails clickwrap:doctor` is a read-only diagnosis an operator reads at
# 03:00. Every finding it prints is an objective fact about this installation's
# configuration or data, there is no overall verdict line, and a run with no
# warnings means only that the listed checks found nothing objectionable.
#
# The last test in this file is the one that keeps that promise honest.
class DoctorTest < ActiveSupport::TestCase
  setup do
    @user = create_user
    @operator = create_security_operator
  end

  # --- Configuration ----------------------------------------------------------

  test "the report states how many policies compiled and that their documents are published" do
    findings = Clickwrap::Doctor.new.report

    assert_equal "#{Clickwrap.policies.size} policies compiled", message_for(findings, /policies compiled/)
    assert ok?(findings, /policies compiled/)

    documents = message_for(findings, /documents are published/)
    assert_match(/all referenced documents are published and digest-verified/, documents)
    assert ok?(findings, /documents are published/)

    # The other configuration facts a fresh dummy install produces, each stated
    # as a fact rather than as a verdict about the application.
    assert ok?(findings, /request-derived personal data is off by default/)
    assert ok?(findings, /no overdue disposition/)
    assert ok?(findings, /no legal holds are in effect/)
    assert_empty findings.select(&:problem?)
  end

  test "a report with nothing compiled says so instead of saying everything is fine" do
    Clickwrap.reset!
    findings = Clickwrap::Doctor.new.report

    # An empty registry is the most likely symptom of config/clickwrap.rb never
    # having been loaded, and a doctor that printed "0 policies compiled ✓"
    # would be reassuring about the one thing that is broken.
    assert warning?(findings, /no policies are compiled/)
    assert_match(%r{config/clickwrap\.rb}, message_for(findings, /no policies are compiled/))
    assert ok?(findings, /no policy references a document/)
  end

  test "a policy recording only an IP address past its review date is exactly as overdue" do
    # The review-date check must cover EVERY collected category — an earlier
    # version was gated on geolocation, so nine IP/user-agent money-path
    # policies in a real host would have sailed past their review date with a
    # green doctor.
    Clickwrap.policy :ip_only_probe do
      acknowledge :withdrawal_requirements, statement: "I acknowledge the withdrawal requirements."

      record_ip_address(encrypted: true, delete_after: 2.years,
                        because: "Investigate disputed submissions")
      review_request_evidence_configuration_on Date.new(2020, 1, 1)

      retain_with :regulated_evidence
    end

    findings = Clickwrap::Doctor.new.report
    warning = message_for(findings, /ip_only_probe was due/)

    assert_match(/ip_address/, warning)
    assert_match(/2020-01-01/, warning)
    assert_match(/that date has passed/, warning)
  end

  test "a policy recording IP geolocation with no review date is a warning" do
    Clickwrap.policy :geolocation_probe do
      acknowledge :withdrawal_requirements, statement: "I acknowledge the withdrawal requirements."

      record_ip_geolocation(country: true, city: true,
                            retain_until: :security_evidence_retention_ends,
                            because: "Corroborate anomalous access")

      retain_with :regulated_evidence
    end

    findings = Clickwrap::Doctor.new.report
    warning = message_for(findings, /geolocation_probe records ip_geolocation/)

    # A decision nobody revisits is how a temporary measure becomes permanent.
    # The date is the host's to choose; the doctor only notices its absence.
    assert_match(%r{country/city without a review date}, warning)
    assert_match(/review_request_evidence_configuration_on/, warning)

    # Resolver capability mismatches are compiler failures now; the doctor is
    # responsible for the operational review date that can change with time.
  end

  test "a review date that has passed is a warning naming the policy and the date" do
    travel_to Date.new(2028, 1, 1) do
      findings = Clickwrap::Doctor.new.report
      warning = message_for(findings, /regulated_authorization was due/)

      assert_match(/reviewed on 2027-08-15/, warning)
      assert_match(/that date has passed/, warning)
      assert warning?(findings, /regulated_authorization was due/)
    end
  end

  test "a resolver Clickwrap adopted says so, rather than reading as a host decision" do
    Clickwrap.config.ip_geolocation_resolver = nil
    adopted = Clickwrap::IpGeolocation::StaticResolver.new
    Clickwrap.config.stubs(:ip_geolocation_resolver_in_force).returns(adopted)
    Clickwrap.config.stubs(:ip_geolocation_resolver_was_adopted_automatically?).returns(true)

    findings = Clickwrap::Doctor.new.report

    assert ok?(findings, /Clickwrap adopted/)
    assert_match(/bundles trackdown and named no resolver of its own/,
                 message_for(findings, /Clickwrap adopted/))
  end

  test "recording IP addresses with no reviewed proxy configuration is a warning" do
    # Since 0.3.0 this boots: a nil digest is recorded as the honest absence of
    # reviewed proxy provenance rather than refused. Doctor is where the nudge
    # lives now — a warning an operator can read and act on, not a wall between
    # an integrator and any evidence at all.
    Clickwrap.config.trusted_proxy_configuration_digest = nil
    Clickwrap.config.record_ip_address_by_default = true
    Clickwrap.config.reason_for_recording_ip_addresses_by_default = "Investigate account compromise"
    Clickwrap.config.delete_recorded_ip_addresses_after = 90.days

    findings = Clickwrap::Doctor.new.report

    # An address read from a forwarded header is only as good as the proxy
    # configuration in front of it. Clickwrap cannot check the host's CDN; what
    # it can check is whether anyone recorded having reviewed one.
    assert warning?(findings, /request-source trust is unverified/)
    assert warning?(findings, /recorded by default for every policy/)
    assert warning?(findings, /no\s+`review_default_request_evidence_configuration_on` date/)

    Clickwrap.config.trusted_proxy_configuration_digest =
      Clickwrap::Digest.digest("reviewed trusted proxy configuration 2026-08")
    assert ok?(Clickwrap::Doctor.new.report, /trusted-proxy configuration digest is recorded/)
  end

  # --- Data -------------------------------------------------------------------

  test "a document whose stored bytes no longer match its recorded digest is a problem" do
    submit_clickwrap(:signup, actor: @user)

    Clickwrap::Document.find_by(document_key: "terms").current_version
                       .update_columns(content: "rewritten after it was published")

    findings = Clickwrap::Doctor.new.report
    problem = findings.find(&:problem?)

    # Every receipt citing that version binds bytes that are no longer there, so
    # this is a problem rather than a warning: the evidence cannot be reproduced.
    assert problem, "an edited published document must be reported as a problem"
    assert_match(/no longer match the digest recorded when it was published/, problem.message)
    assert_match(/cannot be reproduced/, problem.message)
    assert_equal "✗", problem.to_s[0]
  end

  test "an event whose bytes changed after it was written is a problem that names one of them" do
    receipt = submit_clickwrap(:signup, actor: @user)
    Clickwrap::Event.where(id: receipt.event_id).update_all(reason: "rewritten by hand")

    findings = Clickwrap::Doctor.new.report
    problem = findings.find { |finding| finding.problem? && finding.message.include?("event digests") }

    assert problem
    assert_match(/#{receipt.event_id}/, problem.message)

    # It says what a failing digest does and does not establish. A row that no
    # longer matches its digest changed; who changed it is a separate question
    # this cannot answer.
    assert_match(/it does not on its own say who changed them/, problem.message)
  end

  test "a documented core disposition is reported separately from a digest mismatch" do
    receipt = submit_clickwrap(:signup, actor: @user)
    Clickwrap::Retention::Disposition.dispose_core_event!(
      receipt.event,
      because: "The reviewed retention period ended"
    )

    findings = Clickwrap::Doctor.new.report
    digest_finding = findings.find { |finding| finding.message.include?("core disposition") }

    assert digest_finding&.ok?
    assert_match(/1 core disposition is documented by valid linked events/, digest_finding.message)
    assert_match(/no mismatch is unexplained/, digest_finding.message)
    assert_empty(findings.select { |finding| finding.problem? && finding.message.include?("event digests") })
  end

  test "an unexplained disposition marker remains an integrity problem" do
    receipt = submit_clickwrap(:signup, actor: @user)
    Clickwrap::Event.where(id: receipt.event_id).update_all(core_event_disposed_at: Clickwrap.now)

    finding = Clickwrap::Doctor.new.report.find do |candidate|
      candidate.problem? && candidate.message.include?("event digests")
    end

    assert finding
    assert_match(/no valid linked disposition event/, finding.message)
    assert_match(/unexplained disposition marker/, finding.message)
  end

  test "configured integrity work missing after commit is visible until it is reconciled" do
    receipt = submit_clickwrap(:signup, actor: @user)
    adapter = Class.new do
      def timestamp(digest)
        { issued: true, token: "doctor-token", digest: digest, provider_name: "doctor_test" }
      end

      def verify(token, _digest)
        { checked: true, verified: token == "doctor-token" }
      end

      def capabilities = { name: "doctor_test", independently_verifiable: true }
    end.new
    Clickwrap.config.timestamp_receipts_with = adapter

    findings = Clickwrap::Doctor.new.report
    assert warning?(findings, /integrity attestation attempt is missing/)
    assert_match(/clickwrap:integrity:attest_missing/, message_for(findings, /attestation attempt is missing/))

    Clickwrap.reconcile_missing_integrity_attestations!
    reconciled = Clickwrap::Doctor.new.report

    assert ok?(reconciled, /every eligible event has an attestation attempt/)
    assert receipt.event.integrity_attestations.exists?(kind: "third_party_timestamp")
  end

  test "records past a retention rule and holds past their review date are warnings" do
    submit_clickwrap(:signup, actor: @user)
    held = submit_clickwrap(:signup, actor: create_user)
    held.place_on_legal_hold!(because: "Pending dispute 2026-184", placed_by: @operator,
                              review_at: 1.month.from_now)

    assert ok?(Clickwrap::Doctor.new.report, /legal hold in effect, none past review/)

    travel_to 7.years.from_now do
      findings = Clickwrap::Doctor.new.report

      assert warning?(findings, /past a retention rule and still here/)
      assert_match(/clickwrap:retention:plan/, message_for(findings, /past a retention rule/))

      # A hold nobody revisits is how everything gets kept forever, so the
      # review date passing is itself a finding.
      assert warning?(findings, /past the review date they were placed with/)
    end
  end

  test "an external action still pending is reported with the task that lists it" do
    withdrawal = create_withdrawal(user: @user)
    presentation = present_clickwrap(:withdrawal_authorization, actor: @user, subject: withdrawal)

    answers = { withdrawal_requirements: "1", coverage_exclusivity: "1", withdrawal: "1" }

    Clickwrap.authorize_external_action!(
      :withdrawal_authorization,
      actor: @user,
      subject: withdrawal,
      provider_name: "stripe",
      submission: submission_for(presentation, answers)
    )

    findings = Clickwrap::Doctor.new.report

    assert warning?(findings, /external action is still\s+pending or unknown/)
    assert_match(/clickwrap:reconcile_external_actions/, message_for(findings, /pending or unknown/))
  end

  # --- Rendering --------------------------------------------------------------

  test "to_s renders one line per finding with a tick or an exclamation mark" do
    findings = Clickwrap::Doctor.new.report
    lines = Clickwrap::Doctor.new.to_s.lines.map(&:chomp)

    assert_equal findings.length, lines.length
    assert lines.all? { |line| line.start_with?("✓ ", "! ", "✗ ") },
           "every line must carry its status symbol: #{lines.inspect}"
    assert_equal "✓ #{findings.first.message}", lines.first

    # There is deliberately no summary line. A green verdict would be a legal
    # determination made on the host's behalf, which is the one thing this gem
    # exists not to do.
    assert_no_match(/^(all clear|no problems found|you are|everything)/i, lines.last)
  end

  test "the report never prints a phrase that would overclaim what it checked" do
    # Run the checks under the conditions that produce the most text: warnings,
    # problems, and the data findings all at once.
    submit_clickwrap(:signup, actor: @user)
    Clickwrap::Document.find_by(document_key: "terms").current_version.update_columns(content: "rewritten")

    printed = travel_to(Date.new(2028, 1, 1)) { Clickwrap::Doctor.new.to_s.downcase }

    Clickwrap::Doctor::PHRASES_THIS_REPORT_NEVER_PRINTS.each do |phrase|
      assert_not_includes printed, phrase,
                          "the doctor printed #{phrase.inspect}, which claims something no " \
                          "configuration check can establish"
    end

    Clickwrap::Vocabulary::PROHIBITED_CLAIM_PHRASES.each do |phrase|
      assert_not_includes printed, phrase
    end
  end

  private

  def finding_for(findings, pattern)
    findings.find { |finding| finding.message.match?(pattern) }
  end

  def message_for(findings, pattern)
    finding = finding_for(findings, pattern)
    assert finding, "no finding matched #{pattern.inspect} in: #{findings.map(&:to_s).inspect}"
    finding.message
  end

  def ok?(findings, pattern)
    finding_for(findings, pattern)&.ok?
  end

  def warning?(findings, pattern)
    finding_for(findings, pattern)&.warning?
  end
end
