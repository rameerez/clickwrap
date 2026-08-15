# frozen_string_literal: true

require "test_helper"

# The backward-compatibility promise, made executable.
#
# `test/fixtures/receipts/` holds real receipts, byte for byte, frozen before
# the first release of each schema. They are never regenerated after that
# schema ships. Every release runs the CURRENT verifier against them, so the day someone changes
# canonicalization, a digest rule, a field name, or a schema meaning, this file
# fails — which is the only mechanism that makes "we still verify receipts you
# exported years ago" a fact rather than an intention.
#
# When a receipt format legitimately changes, the correct move is to add a new
# fixture under the new schema name and LEAVE THESE ALONE. A fixture that gets
# updated to match new behavior has stopped testing anything.
class GoldenReceiptsTest < ActiveSupport::TestCase
  FIXTURE_DIR = File.expand_path("fixtures/receipts", __dir__)
  DOCUMENT_DIR = File.join(FIXTURE_DIR, "documents")
  EXPECTED_VERIFICATION_STATUS = {
    "disposed_core.clickwrap.receipt.v1.json" => "incomplete"
  }.freeze

  REQUEST_EVIDENCE_STATES = {
    "request_evidence_recorded.clickwrap.receipt.v1.json" => {
      "browser_user_agent" => "recorded",
      "ip_address" => "recorded",
      "ip_geolocation" => "recorded"
    },
    "request_evidence_redacted.clickwrap.receipt.v1.json" => {
      "browser_user_agent" => "redacted_for_this_viewer",
      "ip_address" => "redacted_for_this_viewer",
      "ip_geolocation" => "redacted_for_this_viewer"
    },
    "request_evidence_deleted_after_retention.clickwrap.receipt.v1.json" => {
      "browser_user_agent" => "deleted_after_retention",
      "ip_address" => "deleted_after_retention",
      "ip_geolocation" => "deleted_after_retention"
    },
    "request_evidence_held.clickwrap.receipt.v1.json" => {
      "browser_user_agent" => "held",
      "ip_address" => "held",
      "ip_geolocation" => "held"
    },
    "request_evidence_unavailable.clickwrap.receipt.v1.json" => {
      "browser_user_agent" => "redacted_for_this_viewer",
      "ip_address" => "redacted_for_this_viewer",
      "ip_geolocation" => "unavailable"
    }
  }.freeze

  def self.fixtures_on_disk
    Dir[File.join(FIXTURE_DIR, "*.json")]
  end

  test "there is at least one golden receipt to check against" do
    # A guard against the whole file silently becoming a no-op if the fixtures
    # are ever moved or deleted.
    assert_operator self.class.fixtures_on_disk.length, :>=, 3
  end

  test "every schema the verifier advertises has a frozen fixture" do
    schemas_on_disk = self.class.fixtures_on_disk.map do |path|
      JSON.parse(File.read(path)).fetch("schema")
    end.uniq

    assert_empty Clickwrap::ReceiptVerifier::KNOWN_SCHEMAS - schemas_on_disk,
                 "KNOWN_SCHEMAS must not grow until a receipt from the new schema is frozen here"
  end

  fixtures_on_disk.each do |path|
    name = File.basename(path, ".json")

    test "the current verifier preserves the expected status of golden receipt #{name}" do
      json = File.read(path)
      result = Clickwrap::ReceiptVerifier.verify(json, documents: golden_documents)
      expected = EXPECTED_VERIFICATION_STATUS.fetch(File.basename(path), "verified")

      assert_equal expected, result.status, "#{name} changed verification status:\n#{result}"
    end

    test "the golden receipt #{name} is still canonical under the current rules" do
      json = File.read(path)

      # If canonicalization changed, these bytes would no longer round-trip —
      # and every receipt already exported would be unverifiable by the new
      # code. That is a breaking change to persisted evidence, not a refactor.
      assert_equal json, Clickwrap::CanonicalJson.canonicalize(json),
                   "canonicalization changed: #{name} is no longer its own canonical form"
    end

    test "the golden receipt #{name} still declares a schema this verifier knows" do
      body = JSON.parse(File.read(path))

      assert_includes Clickwrap::ReceiptVerifier::KNOWN_SCHEMAS, body["schema"]
    end
  end

  test "the golden receipts still carry the fields a reader depends on" do
    body = JSON.parse(File.read(File.join(FIXTURE_DIR, "signup.clickwrap.receipt.v1.json")))

    # These are the load-bearing names. Renaming one is not a refactor: it is a
    # change to a published format that other people's tooling reads.
    %w[schema event_id event_type event policy actor acts documents presentation
       integrity retention recorded_at_by_server system verifier_instructions].each do |key|
      assert body.key?(key), "the receipt format lost the #{key.inspect} key"
    end

    assert body.dig("integrity", "receipt_digest").to_s.start_with?("sha256:")
    assert body.dig("integrity", "event_digest").to_s.start_with?("sha256:")
    assert body.dig("integrity", "detects").present?
    assert body.dig("presentation", "proves").present?
  end

  test "the golden receipts still report all three request-evidence categories by state" do
    body = JSON.parse(File.read(File.join(FIXTURE_DIR, "signup.clickwrap.receipt.v1.json")))
    request_evidence = body["request_evidence"]

    assert_equal %w[browser_user_agent ip_address ip_geolocation], request_evidence.keys.sort

    # Dropping a category from a receipt when a policy did not collect it would
    # make "we never collected this" indistinguishable from "this receipt
    # predates the field", years after anyone can ask.
    request_evidence.each_value { |fragment| assert fragment.key?("state") }
  end

  test "every request-evidence state has an explicit frozen fixture" do
    REQUEST_EVIDENCE_STATES.each do |filename, expected_states|
      body = JSON.parse(File.read(File.join(FIXTURE_DIR, filename)))
      actual_states = body.fetch("request_evidence").transform_values { |fragment| fragment.fetch("state") }

      assert_equal expected_states, actual_states, filename
    end
  end

  test "the disposed-core fixture is a documented incomplete verification, not a failure" do
    path = File.join(FIXTURE_DIR, "disposed_core.clickwrap.receipt.v1.json")
    result = Clickwrap::ReceiptVerifier.verify(File.read(path), documents: golden_documents)

    assert result.incomplete?, result.to_s
    assert_empty result.failures
    event_check = result.checks.find { |check| check.name == "event_digest" }
    assert event_check.skipped?
    assert_match(/lawfully disposed/, event_check.detail)
  end

  test "the golden receipts contain no prohibited claim" do
    self.class.fixtures_on_disk.each do |path|
      contents = File.read(path).downcase

      Clickwrap::Vocabulary::PROHIBITED_CLAIM_PHRASES.each do |phrase|
        assert_not contents.include?(phrase),
                   "#{File.basename(path)} contains the prohibited claim #{phrase.inspect}"
      end
    end
  end

  test "a golden receipt fails verification if a document's bytes are not the ones it cites" do
    json = File.read(File.join(FIXTURE_DIR, "signup.clickwrap.receipt.v1.json"))
    documents = golden_documents
    documents.fetch("terms@2026-08-15@en")["source"] = "not the source bytes the receipt bound"

    result = Clickwrap::ReceiptVerifier.verify(
      json, documents: documents
    )

    assert_not result.success?
    assert(result.failures.any? { |check| check.name.include?("terms") })
  end

  private

  def golden_documents
    document_bindings = self.class.fixtures_on_disk.flat_map do |path|
      Array(JSON.parse(File.read(path))["documents"])
    end

    document_bindings.each_with_object({}) do |binding, artifacts|
      identity = [binding.fetch("key"), binding.fetch("version"), binding.fetch("locale")].join("@")
      next if artifacts.key?(identity)

      stem = [binding.fetch("key"), binding.fetch("version"), binding.fetch("locale")].join("-")
      artifacts[identity] = %w[source rendered].to_h do |kind|
        paths = Dir[File.join(DOCUMENT_DIR, "#{stem}.#{kind}.*")]
        assert_equal 1, paths.length,
                     "golden document #{identity} needs exactly one #{kind} artifact"
        [kind, File.binread(paths.fetch(0))]
      end
    end
  end
end
