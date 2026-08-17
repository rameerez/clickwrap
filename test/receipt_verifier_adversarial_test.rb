# frozen_string_literal: true

require "test_helper"

# Hostile and incomplete receipt shapes. The standalone verifier is a security
# boundary: every malformed input must become a structured failed/incomplete
# result, never an exception, guessed schema, or unearned green check.
class ReceiptVerifierAdversarialTest < ActiveSupport::TestCase
  setup do
    @user = create_user
    @receipt = submit_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
    @body = @receipt.to_h
  end

  test "parsing, schema refusal, bang verification, and result states are total" do
    [nil, "", "[]", "{", '{"schema":"one","schema":"two"}'].each do |input|
      result = nil
      capture_io { result = Clickwrap::ReceiptVerifier.verify(input) }

      assert result.failed?
      assert_equal "failed", result.status
      assert result.failures.any?
      assert_match(/FAILED/, result.to_s)
      assert_match(/failed/, result.inspect)
      assert_equal false, result.to_h["success"]
    end

    unknown = canonical_json_for({ "schema" => "clickwrap.receipt.v999" })
    unknown_result = Clickwrap::ReceiptVerifier.verify(unknown)
    assert unknown_result.failed?
    assert_equal "known_schema", unknown_result.failures.first.name
    assert_raises(Clickwrap::UnknownReceiptSchema) { Clickwrap::ReceiptVerifier.verify!(unknown) }

    assert Clickwrap::ReceiptVerifier.verify!(canonical_json_for(copy(@body)), documents: artifacts).success?

    changed = copy(@body)
    changed["actor"]["reference"] = "rewritten"
    assert_raises(Clickwrap::ReceiptInvalid) do
      Clickwrap::ReceiptVerifier.verify!(Clickwrap::CanonicalJson.generate(changed))
    end
  end

  test "canonical bytes and both digest layers fail independently and never raise" do
    pretty = JSON.pretty_generate(@body)
    result = Clickwrap::ReceiptVerifier.verify(pretty, documents: artifacts)
    assert failed_check(result, "canonical_bytes")
    assert passed_check(result, "receipt_digest")

    missing_integrity = copy(@body)
    missing_integrity.delete("integrity")
    result = Clickwrap::ReceiptVerifier.verify(canonical_json_for(missing_integrity))
    assert failed_check(result, "receipt_digest")
    assert failed_check(result, "event_digest")

    non_object_integrity = copy(@body)
    non_object_integrity["integrity"] = "not an object"
    result = Clickwrap::ReceiptVerifier.verify(canonical_json_for(non_object_integrity))
    assert failed_check(result, "receipt_digest")

    missing_receipt_digest = copy(@body)
    missing_receipt_digest["integrity"].delete("receipt_digest")
    assert failed_check(verify_raw(missing_receipt_digest), "receipt_digest")

    unsupported_receipt_digest = copy(@body)
    unsupported_receipt_digest["integrity"]["receipt_digest"] = "md5:abc"
    assert failed_check(verify_raw(unsupported_receipt_digest), "receipt_digest")

    wrong_receipt_digest = copy(@body)
    wrong_receipt_digest["integrity"]["receipt_digest"] = "sha256:#{"0" * 64}"
    assert failed_check(verify_raw(wrong_receipt_digest), "receipt_digest")

    missing_event = copy(@body)
    missing_event.delete("event")
    assert failed_check(verify_resigned(missing_event), "event_digest")

    unsupported_event_digest = copy(@body)
    unsupported_event_digest["integrity"]["event_digest"] = "md5:abc"
    assert failed_check(verify_resigned(unsupported_event_digest), "event_digest")

    wrong_event_digest = copy(@body)
    wrong_event_digest["event"]["reason"] = "rewritten"
    assert failed_check(verify_resigned(wrong_event_digest), "event_digest")

    # JSON's huge exponent becomes a non-finite Float on parsers that permit it.
    # Either parse refusal or canonicalization refusal is acceptable; crashing is
    # not. This used to escape the verifier as a serialization exception.
    huge_number = Clickwrap::ReceiptVerifier.verify('{"schema":"clickwrap.receipt.v1","x":1e999}')
    assert huge_number.failed?
  end

  test "every duplicated receipt projection is compared with the embedded event" do
    body = copy(@body)
    body["event_id"] = "different-event"
    body["event_type"] = "different-type"
    body["policy"] = { "key" => "different", "revision" => "different", "retention_class" => "different" }
    body["actor"] = {
      "reference" => "different-actor",
      "attribution" => { "authenticated" => true, "method" => "different" },
      "snapshot" => { "email" => "different@example.com" },
      "authentication_method" => "different",
      "tenant" => "different",
      "subject" => { "reference" => "different" },
      "acting_for" => { "reference" => "different" }
    }
    body["acts"] = []
    body["documents"] = []
    body["presentation"] = { "manifest_digest" => "different" }
    body["outcome"] = { "different" => true }
    body["provider"] = { "name" => "different" }
    body["lifecycle"] = { "root_event_id" => "different", "predecessor_event_id" => "different" }
    body["retention"] = {
      "class" => "different",
      "core_event_retained_until" => "different",
      "retention_rule" => "different"
    }
    body["integrity"]["chain_scope"] = "different"
    body["integrity"]["chain_sequence"] = 99
    body["integrity"]["request_evidence_category_binding_digests"] = { "ip_address" => "different" }
    body["integrity"]["request_evidence_digest_algorithm"] = "different"
    body["integrity"]["request_evidence_key_id"] = "different"
    body["recorded_at_by_server"] = "different"
    body["occurred_at"] = "different"
    body["system"] = {
      "gem_version" => "different",
      "application_version" => "different",
      "template_version" => "different",
      "canonical_schema_version" => "different"
    }

    check = failed_check(verify_resigned(body), "event_digest")
    %w[event_id event_type policy.key actor.reference acts documents presentation outcome provider
       lifecycle.root_event_id retention.core_event_retained_until integrity.chain
       integrity.request_evidence recorded_at_by_server system.gem_version].each do |field|
      assert_includes check.detail, field
    end
  end

  test "represented-party, provider, presentation, chain, and request bindings can agree exactly" do
    body = copy(@body)
    event = body.fetch("event")
    event["actor"]["represented_party"] = { "type" => "Organization", "reference" => "gid://app/Org/1" }
    event["actor"]["authority"] = {
      "source" => "membership",
      "role" => "admin",
      "verified_at" => "2026-08-15T12:00:00.000000Z",
      "details" => { "membership" => "1" }
    }
    body["actor"]["acting_for"] = {
      "type" => "Organization",
      "reference" => "gid://app/Org/1",
      "authority_source" => "membership",
      "authority_role" => "admin",
      "authority_verified_at" => "2026-08-15T12:00:00.000000Z",
      "authority_details" => { "membership" => "1" }
    }
    event["provider"] = { "name" => "provider", "event_id" => "provider-1", "verification" => { "ok" => true } }
    body["provider"] = event["provider"].merge("note" => "projection-only explanation")
    body["presentation"]["proves"] = "A bounded explanation omitted from the canonical event projection."
    event["chain"] = { "scope" => "org/policy", "sequence" => 1 }
    body["integrity"]["chain_scope"] = "org/policy"
    body["integrity"]["chain_sequence"] = 1
    event["request_evidence"] = {
      "category_digests" => { "ip_address" => "hmac-sha256:abc" },
      "algorithm" => "hmac-sha256",
      "key_id" => "key-1"
    }
    body["integrity"]["request_evidence_category_binding_digests"] = { "ip_address" => "hmac-sha256:abc" }
    body["integrity"]["request_evidence_digest_algorithm"] = "hmac-sha256"
    body["integrity"]["request_evidence_key_id"] = "key-1"
    body["integrity"]["tier"] = "chained_history"

    result = Clickwrap::ReceiptVerifier.verify(resign(body, resign_event: true), documents: artifacts)
    assert passed_check(result, "event_digest")
    assert passed_check(result, "chain_linkage")
    assert passed_check(result, "integrity_tier")
  end

  test "core disposition requires one linked digest-valid successor and a scrubbed tombstone" do
    Clickwrap::Retention::Disposition.dispose_core_event!(
      @receipt.event,
      because: "The reviewed retention period ended"
    )
    valid = Clickwrap.receipt(@receipt.event_id).to_h
    assert skipped_check(verify_resigned(valid), "event_digest")

    no_successor = copy(valid)
    no_successor["lifecycle"]["successors"] = []
    assert_match(/no core-event disposition successor/,
                 failed_check(verify_resigned(no_successor), "event_digest").detail)

    duplicate = copy(valid)
    duplicate["lifecycle"]["successors"] << copy(duplicate["lifecycle"]["successors"].first)
    assert_match(/more than one/, failed_check(verify_resigned(duplicate), "event_digest").detail)

    hostile = copy(valid)
    successor = hostile.dig("lifecycle", "successors").first
    facts = successor.dig("event", "protected_outcome", "core_event_disposition")
    facts["event_id"] = "different"
    facts["original_event_digest"] = "sha256:#{"0" * 64}"
    facts["disposed_at"] = "different"
    successor["event"]["event_type"] = "capture"
    successor["event"]["root_event_id"] = "different"
    successor["event"]["predecessor_event_id"] = "different"
    hostile["acts"] = [{ "left" => true }]
    hostile["documents"] = [{ "left" => true }]
    hostile["actor"]["reference"] = "left"
    hostile["presentation"] = { "left" => true }
    hostile["outcome"] = { "left" => true }
    hostile["event"]["acts"] = [{ "left" => true }]
    hostile["event"]["documents"] = [{ "left" => true }]
    hostile["event"]["actor"]["reference"] = "left"
    hostile["event"]["presentation"] = { "left" => true }
    hostile["event"]["protected_outcome"] = { "left" => true }

    detail = failed_check(verify_resigned(hostile), "event_digest").detail
    %w[different wrong linked remain].each { |word| assert_includes detail, word }
  end

  test "lifecycle successor validation rejects malformed, duplicated, altered, and unlinked events" do
    non_array = copy(@body)
    non_array["lifecycle"] = { "successors" => "not an array" }
    assert failed_check(verify_resigned(non_array), "lifecycle_successors")

    missing_event = copy(@body)
    missing_event["lifecycle"] = { "successors" => [nil] }
    assert failed_check(verify_resigned(missing_event), "lifecycle_successor:0")

    bad = copy(@body)
    successor_event = {
      "event_id" => "successor-1",
      "event_type" => "withdrawal",
      "recorded_at_by_server" => bad["recorded_at_by_server"],
      "reason" => "withdrawn",
      "root_event_id" => "not-the-root"
    }
    successor = {
      "event" => successor_event,
      "event_id" => "different-summary",
      "event_type" => "different-summary",
      "recorded_at_by_server" => "different-summary",
      "reason" => "different-summary",
      "event_digest" => "md5:unsupported"
    }
    bad["lifecycle"] = { "successors" => [successor, copy(successor)] }
    result = verify_resigned(bad)
    checks = result.failures.select { |check| check.name.start_with?("lifecycle_successor") }
    assert_equal 2, checks.length
    assert(checks.any? { |check| check.detail.include?("duplicated") })
    assert(checks.all? { |check| check.detail.include?("not linked") })

    matching = copy(@body)
    successor_event["root_event_id"] = matching["event_id"]
    successor["event_id"] = successor_event["event_id"]
    successor["event_type"] = successor_event["event_type"]
    successor["recorded_at_by_server"] = successor_event["recorded_at_by_server"]
    successor["reason"] = successor_event["reason"]
    successor["event_digest"] = Clickwrap::Digest.digest_canonical(successor_event)
    matching["lifecycle"] = { "successors" => [successor] }
    assert passed_check(verify_resigned(matching), "lifecycle_successor:successor-1")
  end

  test "attestation records are validated before they can upgrade the advertised tier" do
    non_array = copy(@body)
    non_array["integrity"]["attestations"] = "not an array"
    assert failed_check(verify_resigned(non_array), "integrity_attestations")

    malformed = copy(@body)
    malformed["integrity"]["attestations"] = [nil]
    assert failed_check(verify_resigned(malformed), "integrity_attestation:0")

    hostile = copy(@body)
    hostile["integrity"]["attestations"] = [{
      "kind" => "unknown",
      "state" => "unknown",
      "attestation_digest" => "md5:unsupported",
      "event_id" => "different",
      "subject_digest" => "different"
    }]
    detail = failed_check(verify_resigned(hostile), "integrity_attestation:unknown:0").detail
    %w[kind state digest event].each { |word| assert_includes detail, word }

    invalid_anchor = chained_body
    attach_attestation(
      invalid_anchor,
      kind: "event_anchor",
      state: "verified",
      chain_scope: "different",
      chain_sequence: 999,
      verification: { "checked" => false, "verified" => false },
      capabilities: { "publishes_outside_primary_database" => true }
    )
    detail = failed_check(verify_resigned(invalid_anchor), "integrity_attestation:event_anchor:0").detail
    assert_includes detail, "chain scope"
    assert_includes detail, "chain sequence"
    assert_includes detail, "recorded adapter verification"

    timestamp = copy(@body)
    attach_attestation(
      timestamp,
      kind: "third_party_timestamp",
      capabilities: { "independently_verifiable" => true }
    )
    timestamp["integrity"]["tier"] = "third_party_timestamp"
    result = verify_resigned(timestamp)
    assert passed_check(result, "integrity_attestation:third_party_timestamp:0")
    assert passed_check(result, "integrity_tier")

    anchor = chained_body
    attach_attestation(
      anchor,
      kind: "event_anchor",
      chain_scope: anchor.dig("integrity", "chain_scope"),
      chain_sequence: anchor.dig("integrity", "chain_sequence"),
      capabilities: { "publishes_outside_primary_database" => true }
    )
    anchor["integrity"]["tier"] = "external_event_anchoring"
    result = verify_resigned(anchor)
    assert passed_check(result, "integrity_attestation:event_anchor:0")
    assert passed_check(result, "integrity_tier")

    anchor["integrity"]["tier"] = "baseline"
    assert failed_check(verify_resigned(anchor), "integrity_tier")
  end

  test "document artifacts support explicit forms and distinguish missing, malformed, and wrong bytes" do
    no_documents = copy(@body)
    no_documents["documents"] = []
    no_documents["event"]["documents"] = []
    assert passed_check(verify_resigned(no_documents, resign_event: true), "documents")

    malformed = copy(@body)
    malformed["documents"] = [nil]
    malformed["event"]["documents"] = [nil]
    assert failed_check(verify_resigned(malformed, resign_event: true), "document:0")

    missing_digest = copy(@body)
    missing_digest["documents"].first.delete("source_digest")
    missing_digest["event"]["documents"].first.delete("source_digest")
    result = verify_resigned(missing_digest, resign_event: true)
    assert(result.failures.any? { |check| check.name.end_with?(":source") })

    incomplete = Clickwrap::ReceiptVerifier.verify(canonical_json_for(copy(@body)))
    assert incomplete.incomplete?
    assert(incomplete.skipped.any? { |check| check.name.start_with?("document:") })

    wrong = Clickwrap::ReceiptVerifier.verify(canonical_json_for(copy(@body)), documents: {
                                                "terms" => { source: "wrong", rendered: "wrong" },
                                                "privacy_notice" => { source: "wrong", rendered: "wrong" }
                                              })
    assert wrong.failed?
    assert(wrong.failures.any? { |check| check.name.start_with?("document:") })

    first = @body.fetch("documents").first
    identity = [first["key"], first["version"], first["locale"]].join("@")
    version = version_for(first)
    explicit = {
      "#{identity}:source" => version.content_bytes,
      "#{identity}:rendered" => version.rendered_bytes
    }
    result = Clickwrap::ReceiptVerifier.verify(canonical_json_for(copy(@body)), documents: explicit)
    assert(result.passed.any? { |check| check.name.include?(identity) && check.name.end_with?(":source") })

    nested_symbol_keys = {
      "#{first["key"]}@#{first["version"]}" => {
        source_bytes: version.content_bytes,
        rendered_bytes: version.rendered_bytes
      }
    }
    result = Clickwrap::ReceiptVerifier.verify(canonical_json_for(copy(@body)), documents: nested_symbol_keys)
    assert(result.passed.any? { |check| check.name.include?(identity) && check.name.end_with?(":rendered") })

    identity_fallback = copy(@body)
    identity_fallback["documents"] = [{ "source_digest" => "bad", "rendered_digest" => "bad" }]
    identity_fallback["event"]["documents"] = copy(identity_fallback["documents"])
    result = verify_resigned(identity_fallback, resign_event: true)
    assert(result.checks.any? { |check| check.name.start_with?("document:0:") })
  end

  test "chain linkage reports each incomplete shape and accepts both chain positions" do
    cases = [
      { "chain_sequence" => 1 },
      { "chain_scope" => "scope" },
      { "chain_scope" => "scope", "chain_sequence" => -1 },
      { "chain_scope" => "scope", "chain_sequence" => "two" },
      { "chain_scope" => "scope", "chain_sequence" => 2 },
      { "chain_scope" => "scope", "chain_sequence" => 2, "previous_event_digest" => "bad" }
    ]

    cases.each do |fields|
      body = copy(@body)
      body["integrity"].merge!(fields)
      result = verify_resigned(body)
      assert failed_check(result, "chain_linkage"), fields.inspect
    end

    first = chained_body
    assert passed_check(verify_resigned(first), "chain_linkage")

    later = chained_body(sequence: 2, previous: Clickwrap::Digest.digest("previous"))
    assert passed_check(verify_resigned(later), "chain_linkage")
  end

  private

  def copy(value)
    JSON.parse(JSON.generate(value))
  end

  def resign(body, resign_event: false)
    body["integrity"]["event_digest"] = Clickwrap::Digest.digest_canonical(body.fetch("event")) if resign_event

    body["integrity"]["receipt_digest"] = Clickwrap::Digest.digest_canonical(
      Clickwrap::ReceiptVerifier.body_covered_by_digest(body)
    )
    Clickwrap::CanonicalJson.generate(body)
  end

  def canonical_json_for(body)
    return Clickwrap::CanonicalJson.generate(body) unless body["integrity"].is_a?(Hash)

    resign(body)
  end

  def verify_raw(body)
    Clickwrap::ReceiptVerifier.verify(Clickwrap::CanonicalJson.generate(body))
  end

  def verify_resigned(body, resign_event: false)
    Clickwrap::ReceiptVerifier.verify(resign(body, resign_event: resign_event))
  end

  def artifacts
    @artifacts ||= @receipt.documents.to_h do |binding|
      version = Clickwrap::DocumentVersion.find(binding.document_version_id)
      [
        "#{binding.document_key}@#{binding.version_label}",
        { source: version.content_bytes, rendered: version.rendered_bytes }
      ]
    end
  end

  def version_for(binding)
    event_binding = @receipt.event.documents.find do |candidate|
      candidate.document_key == binding["key"] && candidate.version_label == binding["version"]
    end
    Clickwrap::DocumentVersion.find(event_binding.document_version_id)
  end

  def chained_body(sequence: 1, previous: nil)
    body = copy(@body)
    body["event"]["chain"] = {
      "scope" => "global/signup",
      "sequence" => sequence,
      "previous_event_digest" => previous
    }.compact
    body["integrity"]["chain_scope"] = "global/signup"
    body["integrity"]["chain_sequence"] = sequence
    body["integrity"]["previous_event_digest"] = previous if previous
    body["integrity"]["tier"] = "chained_history"
    body["integrity"]["event_digest"] = Clickwrap::Digest.digest_canonical(body["event"])
    body
  end

  def attach_attestation(body, kind:, capabilities:, state: "verified", chain_scope: nil,
                         chain_sequence: nil, verification: { "checked" => true, "verified" => true })
    attestation = {
      "event_id" => body["event_id"],
      "kind" => kind,
      "state" => state,
      "provider_name" => "test_provider",
      "subject_digest" => body.dig("integrity", "event_digest"),
      "chain_scope" => chain_scope,
      "chain_sequence" => chain_sequence,
      "verification" => verification,
      "adapter_capabilities" => capabilities,
      "attempted_at" => body["recorded_at_by_server"],
      "created_at" => body["recorded_at_by_server"]
    }.compact
    attestation["attestation_digest"] = Clickwrap::Digest.digest_canonical(attestation)
    body["integrity"]["attestations"] = [attestation]
  end

  def failed_check(result, name)
    result.failures.find { |check| check.name == name }
  end

  def passed_check(result, name)
    result.passed.find { |check| check.name == name }
  end

  def skipped_check(result, name)
    result.skipped.find { |check| check.name == name }
  end
end
