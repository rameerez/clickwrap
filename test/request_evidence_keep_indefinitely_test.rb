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
end
