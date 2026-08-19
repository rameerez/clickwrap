# frozen_string_literal: true

require "test_helper"

# By-default request evidence used to demand a deletion clock — which, since
# 0.2.0 flipped core evidence to keep-indefinitely, meant the corroboration
# (IP, user agent, geolocation) was scheduled to expire before the agreement
# it corroborates. These pin the third option: keeping it as long as the
# evidence itself, said out loud with a reason, never silently.
class RequestEvidenceKeepIndefinitelyTest < ActiveSupport::TestCase
  def enable_ip_defaults!(config)
    config.trusted_proxy_configuration_digest =
      Clickwrap.trusted_proxy_configuration_digest_for([IPAddr.new("10.0.0.0/8")])
    config.record_ip_address_by_default = true
    config.reason_for_recording_ip_addresses_by_default = "Corroborate who performed each act"
  end

  test "an explicit keep-indefinitely satisfies the how-long question" do
    Clickwrap.configure do |config|
      enable_ip_defaults!(config)
      config.keep_recorded_ip_addresses_indefinitely!(
        because: "Corroboration lives as long as the evidence it corroborates"
      )
    end

    assert Clickwrap.config.validate!
    assert Clickwrap.config.keeps_recorded_request_evidence_indefinitely?(:ip_address)
    assert_nil Clickwrap.config.delete_recorded_ip_addresses_after
  end

  test "recording by default with neither a clock nor keep-indefinitely refuses to boot" do
    error = assert_raises(Clickwrap::ConfigurationError) do
      Clickwrap.configure { |config| enable_ip_defaults!(config) }
      Clickwrap.config.validate!
    end

    assert_match(/nothing says how long to keep it/, error.message)
    assert_match(/keep_recorded_ip_addresses_indefinitely!/, error.message)
    assert_match(/delete_recorded_ip_addresses_after/, error.message)
  end

  test "a deletion clock and keep-indefinitely together are refused as opposite decisions" do
    error = assert_raises(Clickwrap::ConfigurationError) do
      Clickwrap.configure do |config|
        enable_ip_defaults!(config)
        config.delete_recorded_ip_addresses_after = 2.years
        config.keep_recorded_ip_addresses_indefinitely!(because: "Also forever")
      end
      Clickwrap.config.validate!
    end

    assert_match(/opposite decisions/, error.message)
  end

  test "keep-indefinitely without a reason is refused" do
    error = assert_raises(Clickwrap::ConfigurationError) do
      Clickwrap.configure do |config|
        config.keep_recorded_browser_user_agents_indefinitely!(because: "  ")
      end
    end

    assert_match(/needs a `because:`/, error.message)
  end
  test "by-default recording under keep-indefinitely compiles, captures, and is never planned" do
    Clickwrap.configure do |config|
      enable_ip_defaults!(config)
      config.keep_recorded_ip_addresses_indefinitely!(
        because: "Corroboration lives as long as the evidence it corroborates"
      )
    end
    # A policy with no retain_with runs under the built-in indefinite class,
    # which carries no annex clocks — so the initializer's declaration is the
    # standing answer. (A retention class's own annex rule, where one exists,
    # rightly outranks it: more specific wins.)
    Clickwrap.policy :keep_pace_probe do
      agree_to :terms, link_label: "Terms of Service"
    end

    user = create_user
    receipt = submit_clickwrap(:keep_pace_probe, actor: user, http_request: fake_http_request)
    annex = receipt.event.reload.request_evidence

    assert annex.present?, "the capture carries a request-evidence annex"
    assert_equal "203.0.113.7", annex.ip_address
    # The blank schedule plus the recorded declaration IS the disposal answer.
    assert_nil annex.ip_address_delete_after
    assert_nil annex.ip_address_retain_until_rule

    travel_to 100.years.from_now do
      planner = Clickwrap::Retention::Planner.new(
        created_by: create_security_operator, because: "Scheduled retention run"
      )
      planner.call
      annex_items = planner.due_items.select { |item| item.event_id == receipt.event_id && item.part == :ip_address }
      assert_empty annex_items, "indefinite request evidence must never become due"
    end
  end

  test "a retention class may keep an annex part indefinitely, in its own words" do
    retention = Clickwrap.retention(:corroboration_keeps_pace) do
      retain_core_event_indefinitely
      keep_recorded_ip_address_indefinitely
    end

    assert retention.rule_for(:ip_address).indefinite?
    assert_equal({ "indefinite" => true }, retention.rule_for(:ip_address).to_snapshot)
  end

  private

  def fake_http_request
    ActionDispatch::TestRequest.create(
      "REMOTE_ADDR" => "203.0.113.7",
      "HTTP_USER_AGENT" => "Mozilla/5.0 (Macintosh) Test/1.0",
      "action_dispatch.request_id" => "req-#{SecureRandom.hex(4)}"
    )
  end
end
