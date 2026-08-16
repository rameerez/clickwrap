# frozen_string_literal: true

require "test_helper"

# A receipt has to still be readable, reproducible, and honest years after the
# code that wrote it has moved on. These tests hold it to that.
class ReceiptTest < ActiveSupport::TestCase
  use_real_database_commits!

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
    assert_match(/\Asha256:[0-9a-f]{64}\z/, terms["source_digest"])
    assert_match(/\Asha256:[0-9a-f]{64}\z/, terms["rendered_digest"])
  end

  test "document presentation order is stored as one consecutive sequence" do
    assert_equal [0, 1], @receipt.event.documents.order(:ordinal).pluck(:ordinal)
    assert_equal([0, 1], @receipt.to_h.fetch("documents").map { |document| document.fetch("ordinal") })
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

  test "the private recording order never leaks into the canonical body or receipt" do
    event = @receipt.event

    # The recording sequence is the installation's private total order — a
    # global counter. Publishing it in receipts would hand every receipt
    # holder an enumerable census of installation activity, so it must never
    # appear in the digested body regardless of whether the column is set.
    assert event.recording_sequence.present?
    refute event.canonical_body.key?("recording_order")
    refute_includes @receipt.to_canonical_json, "recording_order"
    refute_includes @receipt.to_canonical_json, "database_sequence"
  end

  test "a lawfully disposed core event is incomplete rather than failed as tampering" do
    Clickwrap::Retention::Disposition.dispose_core_event!(
      @receipt.event,
      because: "The reviewed retention period ended"
    )
    disposed_receipt = Clickwrap.receipt(@receipt.event_id)

    result = Clickwrap::ReceiptVerifier.verify(disposed_receipt.to_canonical_json)

    assert result.incomplete?, result.to_s
    assert_empty result.failures
    check = result.checks.find { |candidate| candidate.name == "event_digest" }
    assert check.skipped?
    assert_match(/lawfully disposed/, check.detail)
    assert_match(/cannot be re-derived/, check.detail)
    assert_match(/disposed of/, disposed_receipt.to_h.fetch("verifier_instructions"))
  end

  test "an inconsistent core-disposition claim fails verification" do
    Clickwrap::Retention::Disposition.dispose_core_event!(
      @receipt.event,
      because: "The reviewed retention period ended"
    )
    body = Clickwrap.receipt(@receipt.event_id).to_h
    disposition = body.dig("lifecycle", "successors").first
                      .dig("event", "protected_outcome", "core_event_disposition")
    disposition["original_event_digest"] =
      Clickwrap::Digest.digest("a different event")
    body["integrity"]["receipt_digest"] = Clickwrap::Digest.digest_canonical(
      Clickwrap::ReceiptVerifier.body_covered_by_digest(body)
    )

    result = Clickwrap::ReceiptVerifier.verify(Clickwrap::CanonicalJson.generate(body))

    assert result.failed?
    check = result.failures.find { |candidate| candidate.name == "event_digest" }
    assert_match(/different original event digest/, check.detail)
  end

  test "verification fails when a bound document version is edited underneath it" do
    Clickwrap::Document.find_by(document_key: "terms").current_version
                       .update_columns(content: "rewritten after the fact")

    result = @receipt.verify
    assert_not result.success?
    assert_equal :document_digest_mismatch, result.error
  end

  test "the HTML receipt renders the same facts and the same bounded claims" do
    html = @receipt.to_html
    terms = @receipt.to_h.fetch("documents").find { |document| document.fetch("key") == "terms" }

    assert_match(/Evidence receipt/, html)
    assert_match(/#{Regexp.escape(@receipt.event_id)}/, html)
    assert_match(/Agreed to:/, html)
    assert_match(/Acknowledged:/, html)
    assert_includes html, terms.fetch("source_digest")
    assert_includes html, terms.fetch("rendered_digest")
    assert_match(%r{Source \(text/markdown\)}, html)
    assert_match(%r{Rendered \(text/html; charset=utf-8\)}, html)
    assert_match(/What the application offered/, html)
    assert_no_match(/What was on screen/, html)
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

    assert_no_match(/<script>alert/, receipt.to_html)
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

  test "an unredacted export refuses to reveal data inside an outer transaction" do
    operator = create_security_operator

    ActiveRecord::Base.transaction do
      error = assert_raises(Clickwrap::AccessNotAuthorized) do
        Clickwrap::Receipt.export(
          @receipt,
          requested_by: operator,
          because: "Investigating dispute 2026-184",
          include_ip_address: true
        )
      end
      assert_match(/cannot run inside an outer database transaction/, error.message)
      raise ActiveRecord::Rollback
    end

    assert_equal 0, Clickwrap::ReceiptAccess.where(event_id: @receipt.event_id).count
    assert_equal 0,
                 Clickwrap::Event.where(
                   root_event_id: @receipt.event_id,
                   event_type: "receipt_access"
                 ).count
  end

  test "an audit-write failure rolls back the whole sensitive export attempt" do
    operator = create_security_operator

    Clickwrap::Lifecycle.stub(
      :append_lifecycle_event!,
      ->(**_arguments) { raise "audit event unavailable" }
    ) do
      assert_raises(RuntimeError) do
        Clickwrap::Receipt.export(
          @receipt,
          requested_by: operator,
          because: "Investigating dispute 2026-184",
          include_ip_address: true
        )
      end
    end

    assert_equal 0, Clickwrap::ReceiptAccess.where(event_id: @receipt.event_id).count
    assert_equal 0,
                 Clickwrap::Event.where(
                   root_event_id: @receipt.event_id,
                   event_type: "receipt_access"
                 ).count
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
                                         review_at: 6.months.from_now)

    assert hold.in_effect?
    assert @receipt.event.reload.on_legal_hold?
    assert_equal "Pending dispute 2026-184", hold.reason
    assert hold.review_at.present?

    assert_raises(ActiveRecord::RecordInvalid) do
      Clickwrap::LegalHold.create!(hold_scope: "event", event_id: @receipt.event_id,
                                   placed_by_reference: "x", placed_at: Time.current,
                                   review_at: 1.month.from_now)
    end
  end

  test "releasing a hold records who released it and why" do
    operator = create_security_operator
    @receipt.place_on_legal_hold!(because: "Pending dispute", placed_by: operator,
                                  review_at: 6.months.from_now)

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
                                    review_at: 6.months.from_now)
    end

    assert_difference -> { Clickwrap::Event.where(event_type: "legal_hold_released").count }, 1 do
      @receipt.release_legal_hold!(because: "Dispute resolved", released_by: operator)
    end
  end
end
