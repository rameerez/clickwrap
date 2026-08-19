# frozen_string_literal: true

require "test_helper"

# The default retention posture: evidence is kept indefinitely unless the
# application makes the reviewed, explicit decision to schedule deletion.
# Direction matters — keeping is reversible (a disposition can always run
# later), deleting is not, and the day contractual evidence is needed is
# usually years past every convenient clock. So the built-in class
# `evidence_kept_indefinitely` backs any policy that never says `retain_with`,
# an omitted core-event rule means indefinite, and the planner never lists an
# indefinite event as due — not in ten years, not in a hundred.
class RetentionDefaultsTest < ActiveSupport::TestCase
  setup do
    @user = create_user
    @operator = create_security_operator
  end

  test "a policy that never says retain_with keeps its evidence under the built-in class" do
    Clickwrap.policy :quiet_about_retention do
      agree_to :terms, link_label: "Terms of Service"
    end

    policy = Clickwrap.policy!(:quiet_about_retention)
    assert_equal "evidence_kept_indefinitely", policy.retention_class_key

    built_in = Clickwrap.retention_class!("evidence_kept_indefinitely")
    assert built_in.rule_for(:core_event).indefinite?
    # Request evidence carries no deletion clock either: nothing under this
    # class is ever scheduled away.
    assert_nil built_in.rule_for(:ip_address)
  end

  test "an event under the default class freezes no deadline and is never planned" do
    Clickwrap.policy :quiet_about_retention do
      agree_to :terms, link_label: "Terms of Service"
    end

    receipt = submit_clickwrap(:quiet_about_retention, actor: @user)
    event = receipt.event.reload

    # The blank schedule plus the class key IS the recorded decision.
    assert_equal "evidence_kept_indefinitely", event.retention_class_key
    assert_nil event.retain_core_event_until
    assert_nil event.retention_rule_name

    travel_to 100.years.from_now do
      planner = Clickwrap::Retention::Planner.new(created_by: @operator, because: "Scheduled retention run")
      planner.call

      assert_empty planner.due_items.select { |item| item.event_id == receipt.event_id },
                   "an indefinite event must never become due, on any horizon"
    end

    # Asked directly, the answer names the decision rather than a deadline.
    eligibility = Clickwrap::Retention::Planner.core_event_eligibility(event)
    assert_equal "indefinite", eligibility.rule
    assert_not eligibility.due?(Time.current + 100.years)
  end

  test "omitting the core-event rule means indefinite, and saying so out loud means the same" do
    omitted = Clickwrap.retention(:quiet_core) { delete_recorded_ip_address_after 6.years }
    spoken = Clickwrap.retention(:spoken_core) { retain_core_event_indefinitely }

    assert omitted.rule_for(:core_event).indefinite?
    assert spoken.rule_for(:core_event).indefinite?
    assert_equal({ "indefinite" => true }, spoken.rule_for(:core_event).to_snapshot)

    # The deletion clock on the annex part survives beside the indefinite core.
    assert_equal 6.years.to_i, omitted.rule_for(:ip_address).duration.to_i
  end

  test "the privacy inventory reports an indefinite rule as a decision, not a gap" do
    inventory = Clickwrap::Privacy.inventory
    built_in = inventory["retention_classes"]
               .find { |entry| entry["retention_class"] == "evidence_kept_indefinitely" }

    assert built_in, "the built-in class belongs in the privacy inventory"
    assert_equal({ "kind" => "indefinite" }, built_in["rules"]["core_event"])
  end

  test "a scheduled class still schedules: indefinite is the default, never a ceiling" do
    Clickwrap.retention(:short_lived_probe) { retain_core_event_for 6.years }
    Clickwrap.policy :scheduled_probe do
      agree_to :terms, link_label: "Terms of Service"
      retain_with :short_lived_probe
    end

    receipt = submit_clickwrap(:scheduled_probe, actor: @user)
    event = receipt.event.reload

    assert_equal (event.recorded_at_by_server + 6.years).to_i, event.retain_core_event_until.to_i
  end
end
