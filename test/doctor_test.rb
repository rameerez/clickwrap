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

  test "a policy recording IP geolocation with no review date is a warning" do
    Clickwrap.policy :geolocation_probe do
      acknowledge :withdrawal_requirements, statement: "I acknowledge the withdrawal requirements."

      record_ip_geolocation(country: true, city: true,
                            retain_until: :security_evidence_retention_ends,
                            because: "Corroborate anomalous access")

      retain_with :regulated_evidence
    end

    findings = Clickwrap::Doctor.new.report
    warning = message_for(findings, /geolocation_probe records IP geolocation/)

    # A decision nobody revisits is how a temporary measure becomes permanent.
    # The date is the host's to choose; the doctor only notices its absence.
    assert_match(/country, city without a review date/, warning)
    assert_match(/review_request_evidence_configuration_on/, warning)

    # And a policy asking for geolocation with nothing configured to resolve it
    # is reported as a warning, not a failure: capture still succeeds and the
    # field is recorded as unavailable, which is the honest outcome.
    assert warning?(findings, /no\s+`ip_geolocation_resolver` is configured/)
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

  test "recording IP addresses with no reviewed proxy configuration is a warning" do
    Clickwrap.configure do |config|
      config.record_ip_address_by_default = true
      config.reason_for_recording_ip_addresses_by_default = "Investigate account compromise"
      config.delete_recorded_ip_addresses_after = 90.days
    end

    findings = Clickwrap::Doctor.new.report

    # An address read from a forwarded header is only as good as the proxy
    # configuration in front of it. Clickwrap cannot check the host's CDN; what
    # it can check is whether anyone recorded having reviewed one.
    assert warning?(findings, /request-source trust is unverified/)
    assert warning?(findings, /recorded by default for every policy/)
    assert warning?(findings, /no\s+`review_default_request_evidence_configuration_on` date/)

    Clickwrap.config.trusted_proxy_configuration_digest = "sha256:reviewed-2026-08"
    assert ok?(Clickwrap::Doctor.new.report, /trusted-proxy configuration digest is recorded/)
  end

  # --- Data -------------------------------------------------------------------

  test "a document whose stored bytes no longer match its recorded digest is a problem" do
    capture_clickwrap(:signup, actor: @user)

    Clickwrap::Document.find_by(key: "terms").current_version
                       .update_columns(content: "rewritten after it was published")

    findings = Clickwrap::Doctor.new.report
    problem = findings.find(&:problem?)

    # Every receipt citing that version says it presented bytes that are no
    # longer there, so this is a problem rather than a warning: the evidence
    # cannot be reproduced.
    assert problem, "an edited published document must be reported as a problem"
    assert_match(/no longer match the digest recorded when it was published/, problem.message)
    assert_match(/cannot be reproduced/, problem.message)
    assert_equal "✗", problem.to_s[0]
  end

  test "an event whose bytes changed after it was written is a problem that names one of them" do
    receipt = capture_clickwrap(:signup, actor: @user)
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

  test "records past a retention rule and holds past their review date are warnings" do
    capture_clickwrap(:signup, actor: @user)
    held = capture_clickwrap(:signup, actor: create_user)
    held.place_on_legal_hold!(because: "Pending dispute 2026-184", placed_by: @operator,
                              review_on: 1.month.from_now)

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

    answers = { withdrawal_requirements: "1", ride_exclusivity: "1", withdrawal: "1" }

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
    capture_clickwrap(:signup, actor: @user)
    Clickwrap::Document.find_by(key: "terms").current_version.update_columns(content: "rewritten")

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
