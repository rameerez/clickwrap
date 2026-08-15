# frozen_string_literal: true

require "test_helper"

# The backward-compatibility promise, made executable.
#
# `test/fixtures/receipts/` holds real receipts, byte for byte, exactly as some
# earlier version of this gem exported them. They are never regenerated. Every
# release runs the CURRENT verifier against them, so the day someone changes
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

  def self.fixtures_on_disk
    Dir[File.join(FIXTURE_DIR, "*.json")].sort
  end

  test "there is at least one golden receipt to check against" do
    # A guard against the whole file silently becoming a no-op if the fixtures
    # are ever moved or deleted.
    assert_operator self.class.fixtures_on_disk.length, :>=, 3
  end

  fixtures_on_disk.each do |path|
    name = File.basename(path, ".json")

    test "the current verifier still verifies the golden receipt #{name}" do
      json = File.read(path)
      result = Clickwrap::ReceiptVerifier.verify(json, documents: golden_documents)

      assert result.success?, "#{name} no longer verifies:\n#{result}"
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
    %w[schema event_id event_type policy actor acts documents presentation
       integrity retention recorded_at_by_server system verifier_instructions].each do |key|
      assert body.key?(key), "the receipt format lost the #{key.inspect} key"
    end

    assert body.dig("integrity", "receipt_digest").to_s.start_with?("sha256:")
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

    result = Clickwrap::ReceiptVerifier.verify(
      json, documents: golden_documents.merge("terms" => "not the bytes that were presented")
    )

    assert_not result.success?
    assert result.failures.any? { |check| check.name.include?("terms") }
  end

  private

  def golden_documents
    Dir[File.join(DOCUMENT_DIR, "*")].to_h do |path|
      [File.basename(path, File.extname(path)), File.binread(path)]
    end
  end
end
