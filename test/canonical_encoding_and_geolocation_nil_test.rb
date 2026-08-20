# frozen_string_literal: true

require "test_helper"

# Two defects found by review on 2026-08-20, both in the same family: a guard
# that looked like it held and did not.
class CanonicalEncodingAndGeolocationNilTest < ActiveSupport::TestCase
  # --- The canonicalization guard -------------------------------------------

  test "BINARY-tagged bytes that are valid UTF-8 canonicalize byte-identically" do
    # THE safety claim behind fixing the guard: every value that ever reached
    # production arrived from Rack tagged ASCII-8BIT with valid UTF-8 bytes, so
    # normalizing the tag cannot change a digest anyone already wrote.
    tagged = Clickwrap::CanonicalJson.dump({ "city" => "Málaga".b })
    plain = Clickwrap::CanonicalJson.dump({ "city" => "Málaga" })

    assert_equal plain, tagged
    assert_equal plain.bytes, tagged.bytes
    assert_equal Encoding::UTF_8, tagged.encoding
    assert tagged.valid_encoding?
  end

  test "genuinely invalid bytes are refused however they are tagged" do
    # `valid_encoding?` is always true on ASCII-8BIT, so the old guard passed
    # these through and emitted canonical JSON that was not valid UTF-8 — which
    # RFC 8785 forbids, and which a verifier in another language may reject or
    # normalize into a different digest.
    ["M\xFFlaga".b, "M\xFFlaga".dup.force_encoding(Encoding::UTF_8)].each do |value|
      error = assert_raises(Clickwrap::CanonicalJson::SerializationError) do
        Clickwrap::CanonicalJson.dump({ "city" => value })
      end
      assert_match(/valid UTF-8/, error.message)
    end
  end

  test "an annex value that cannot be canonicalized reports a mismatch, never raises" do
    # An integrity check that crashes tells an operator nothing except that the
    # tool broke.
    record_request_evidence_by_default!
    receipt = submit_clickwrap(:signup, actor: create_user, http_request: fake_http_request)
    annex = receipt.event.reload.request_evidence
    annex.define_singleton_method(:binding_body_for) { |_category| { "ip_address" => "1\xFF".b } }

    assert_nothing_raised do
      refute annex.category_binding_digest_verified?(
        category: :ip_address, digest: "whatever",
        algorithm: annex.event.request_evidence_digest_algorithm,
        key_id: annex.event.request_evidence_key_id
      )
    end
  end

  # --- The geolocation nil path ---------------------------------------------

  test "an explicit nil field is refused instead of quietly enabling three" do
    error = assert_raises(Clickwrap::DefinitionError) do
      Clickwrap.policy :geolocation_nil_probe do
        agree_to :terms, link_label: "Terms of Service"
        record_ip_geolocation(country: nil)
      end
    end

    assert_match(/passes nil for country/, error.message)
    assert_match(/will not read an empty value as permission/, error.message)
  end

  test "mentioning nothing still gets the coarse trio; naming one field gets that one" do
    Clickwrap.policy :geolocation_unmentioned_probe do
      agree_to :terms, link_label: "Terms of Service"
      record_ip_geolocation
    end
    assert_equal %w[city country region],
                 Clickwrap.policy!(:geolocation_unmentioned_probe)
                          .request_evidence.enabled_ip_geolocation_fields.map(&:to_s).sort

    Clickwrap.policy :geolocation_one_field_probe do
      agree_to :terms, link_label: "Terms of Service"
      record_ip_geolocation(country: true)
    end
    assert_equal %w[country],
                 Clickwrap.policy!(:geolocation_one_field_probe)
                          .request_evidence.enabled_ip_geolocation_fields.map(&:to_s)
  end

  test "naming every field false still says use do_not_record_ip_geolocation" do
    assert_raises(Clickwrap::DefinitionError) do
      Clickwrap.policy :geolocation_all_false_probe do
        agree_to :terms, link_label: "Terms of Service"
        record_ip_geolocation(country: false)
      end
    end
  end

  # --- Scaffolding in a legal-basis reference --------------------------------

  test "a scaffolding legal-basis reference is refused like a scaffolding purpose" do
    error = assert_raises(Clickwrap::DefinitionError) do
      Clickwrap.policy :legal_basis_todo_probe do
        agree_to :terms, link_label: "Terms of Service"
        record_ip_address(legal_basis_reference: "TODO: ask legal")
      end
    end

    assert_match(/legal_basis_reference/, error.message)
    assert_match(/rather record nothing than record a TODO/, error.message)
  end

  private

  def record_request_evidence_by_default!
    Clickwrap.configure { |config| config.record_request_evidence_by_default = true }
    Clickwrap::Services::LoadPolicies.new(root: Rails.root.to_s, paths: ["config/clickwrap.rb"]).call
  end

  def fake_http_request
    ActionDispatch::TestRequest.create(
      "REMOTE_ADDR" => "203.0.113.7",
      "HTTP_USER_AGENT" => "Mozilla/5.0 (Macintosh) Test/1.0",
      "action_dispatch.request_id" => "req-#{SecureRandom.hex(4)}"
    )
  end
end
