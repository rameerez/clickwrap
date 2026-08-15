# frozen_string_literal: true

require "test_helper"

# A receipt has to still be readable, reproducible, and honest years after the
# code that wrote it has moved on. These tests hold it to that.
class ReceiptTest < ActiveSupport::TestCase
  setup do
    @user = create_user
    @receipt = capture_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
  end

  test "the canonical receipt carries the exact content, presentation, and acts" do
    body = @receipt.to_h

    assert_equal "clickwrap.receipt.v1", body["schema"]
    assert_equal @receipt.event_id, body["event_id"]
    assert_equal "signup", body.dig("policy", "key")
    assert_match(/\Asha256:[0-9a-f]{64}\z/, body.dig("policy", "revision"))

    kinds = body["acts"].map { |act| act["kind"] }
    assert_equal %w[acknowledgment agreement], kinds.sort

    terms = body["documents"].find { |document| document["key"] == "terms" }
    assert_equal "2026-08-15", terms["version"]
    assert_match(/\Asha256:[0-9a-f]{64}\z/, terms["digest"])
  end

  test "the canonical JSON is RFC 8785 canonical and stable" do
    json = @receipt.to_canonical_json

    assert Clickwrap::CanonicalJson.canonical?(json),
           "the receipt must serialize to canonical bytes, not merely to valid JSON"
    assert_equal json, @receipt.to_canonical_json, "canonicalization must be deterministic"
    assert_equal json, Clickwrap::CanonicalJson.canonicalize(json)
  end

  test "the receipt states what the presentation proves and does not overclaim" do
    proves = @receipt.to_h.dig("presentation", "proves")

    assert_match(/server generated this presentation manifest/, proves)
    assert_match(/does not establish/, proves)
    assert_match(/read or understood/, proves)
  end

  test "the receipt states the bounded integrity claim for its tier" do
    integrity = @receipt.to_h["integrity"]

    assert_equal "baseline", integrity["tier"]
    assert_match(/detects accidental or ordinary modification/, integrity["detects"])
    assert_match(/does not establish who produced them/, integrity["detects"])
    assert_no_match(/tamper.?proof/i, integrity["detects"])
  end

  test "request evidence is reported by state, with all three categories always present" do
    fragment = @receipt.to_h["request_evidence"]

    assert_equal %w[browser_user_agent ip_address ip_geolocation], fragment.keys.sort

    # "We chose not to collect this" is a different fact from "collection failed"
    # and from "we deleted it", and the receipt keeps them apart.
    fragment.each_value { |value| assert_equal "not_configured", value["state"] }
  end

  test "raw request evidence is never in the default canonical body" do
    json = @receipt.to_canonical_json

    assert_no_match(/\d+\.\d+\.\d+\.\d+/, json)
    assert_no_match(/Mozilla/, json)
  end

  test "the receipt verifies against its own recorded digest" do
    assert @receipt.digest_verified?
    assert @receipt.verify.success?
  end

  test "verification fails when a bound document version is edited underneath it" do
    Clickwrap::Document.find_by(key: "terms").current_version
                       .update_columns(content: "rewritten after the fact")

    result = @receipt.verify
    assert_not result.success?
    assert_equal :document_digest_mismatch, result.error
  end

  test "the HTML receipt renders the same facts and the same bounded claims" do
    html = @receipt.to_html

    assert_match(/Evidence receipt/, html)
    assert_match(/#{Regexp.escape(@receipt.event_id)}/, html)
    assert_match(/Agreed to:/, html)
    assert_match(/Acknowledged:/, html)
    assert_match(/detects accidental or ordinary modification/, html)
    assert_no_match(/compliant/i, html)
    assert_no_match(/enforceable/i, html)
  end

  test "the HTML receipt escapes content rather than rendering it" do
    Clickwrap.document(:terms, version: "2026-09-09", locale: :en,
                               content: "<script>alert('x')</script>")
    Clickwrap.publish!

    receipt = capture_clickwrap(:signup, actor: create_user,
                                         answers: { terms: "1", privacy_notice: "1" })

    assert_no_match(%r{<script>alert}, receipt.to_html)
  end

  test "to_pdf explains that a PDF is a rendering rather than the record" do
    error = assert_raises(Clickwrap::ConfigurationError) { @receipt.to_pdf }
    assert_match(/rendering of the receipt rather than the record/, error.message)
  end

  # --- Export authorization ---------------------------------------------------

  test "export redacts sensitive fields by default" do
    exported = Clickwrap::Receipt.export(@receipt, requested_by: @user, because: nil)

    assert_equal "not_configured", exported.dig("request_evidence", "ip_address", "state")
  end

  test "asking for unredacted request evidence without a reason is refused" do
    operator = create_security_operator

    error = assert_raises(Clickwrap::AccessNotAuthorized) do
      Clickwrap::Receipt.export(@receipt, requested_by: operator, because: "  ",
                                          include_ip_address: true)
    end

    assert_match(/needs a `because:`/, error.message)
  end

  test "an unauthorized caller cannot read unredacted request evidence" do
    assert_raises(Clickwrap::AccessNotAuthorized) do
      Clickwrap::Receipt.export(@receipt, requested_by: @user, because: "Investigating dispute 2026-184",
                                          include_ip_address: true)
    end
  end

  test "an authorized unredacted export appends an access event" do
    operator = create_security_operator

    assert_difference -> { Clickwrap::ReceiptAccess.count }, 1 do
      Clickwrap::Receipt.export(@receipt, requested_by: operator,
                                          because: "Investigating dispute 2026-184",
                                          include_ip_address: true)
    end

    access = Clickwrap::ReceiptAccess.last
    assert_equal @receipt.event_id, access.event_id
    assert_equal "Investigating dispute 2026-184", access.reason
    assert_equal true, access.included_fields["ip_address"]
    assert_equal false, access.included_fields["browser_user_agent"]
  end

  test "there is no single switch that reveals every sensitive category" do
    # Deliberately absent: one flag that turns on three different categories of
    # personal data makes an operator's intent unreviewable.
    parameters = Clickwrap::Receipt.method(:export).parameters.map(&:last)

    assert_includes parameters, :include_ip_address
    assert_includes parameters, :include_browser_user_agent
    assert_includes parameters, :include_ip_geolocation
    assert_not_includes parameters, :include_sensitive_context
  end

  # --- Legal holds ------------------------------------------------------------

  test "a legal hold requires a reason, an owner, and a review date" do
    operator = create_security_operator

    hold = @receipt.place_on_legal_hold!(because: "Pending dispute 2026-184",
                                         placed_by: operator,
                                         review_on: 6.months.from_now)

    assert hold.in_effect?
    assert @receipt.event.reload.on_legal_hold?
    assert_equal "Pending dispute 2026-184", hold.reason
    assert hold.review_on.present?

    assert_raises(ActiveRecord::RecordInvalid) do
      Clickwrap::LegalHold.create!(scope: "event", event_id: @receipt.event_id,
                                   placed_by_reference: "x", placed_at: Time.current,
                                   review_on: 1.month.from_now)
    end
  end

  test "releasing a hold records who released it and why" do
    operator = create_security_operator
    @receipt.place_on_legal_hold!(because: "Pending dispute", placed_by: operator,
                                  review_on: 6.months.from_now)

    @receipt.release_legal_hold!(because: "Dispute resolved", released_by: operator)

    assert_not @receipt.event.reload.on_legal_hold?
    hold = Clickwrap::LegalHold.for_event(@receipt.event_id).first
    assert hold.released?
    assert_equal "Dispute resolved", hold.release_reason
  end

  test "placing and releasing a hold each append their own event" do
    operator = create_security_operator

    assert_difference -> { Clickwrap::Event.where(event_type: "legal_hold_placed").count }, 1 do
      @receipt.place_on_legal_hold!(because: "Pending dispute", placed_by: operator,
                                    review_on: 6.months.from_now)
    end

    assert_difference -> { Clickwrap::Event.where(event_type: "legal_hold_released").count }, 1 do
      @receipt.release_legal_hold!(because: "Dispute resolved", released_by: operator)
    end
  end
end
