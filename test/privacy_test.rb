# frozen_string_literal: true

require "test_helper"

# `Clickwrap::Privacy` describes a configuration and shows what one actor's
# evidence contains. It never decides anything: not whether a purpose is lawful,
# not whether a period is long enough, and not whether an erasure request
# outranks a retention duty.
#
# These tests hold it to both halves of that — the description has to be
# complete enough to be useful, and it has to stay a description.
class PrivacyTest < ActiveSupport::TestCase
  setup do
    @user = create_user
    @operator = create_security_operator
  end

  # --- The inventory ----------------------------------------------------------

  test "the inventory reads back every field a policy records, why, under what basis, and for how long" do
    configure_static_resolver!
    inventory = Clickwrap::Privacy.inventory

    # Every compiled policy appears, including the ones that record nothing. A
    # policy missing from an inventory reads as a policy that collects nothing,
    # and the two have to be told apart by reading, not by inferring.
    assert_equal Clickwrap.policies.keys.sort, inventory["policies"].map { |policy| policy["policy"] }.sort
    assert_equal "configuration", inventory["describes"]

    regulated = policy_entry(inventory, "regulated_authorization")
    assert regulated["records_any_request_evidence"]
    assert_equal "regulated_evidence", regulated["retention_class"]

    ip_address = regulated["fields"]["ip_address"]
    assert ip_address["recorded"]
    assert_equal "Investigate account compromise and disputes about this action", ip_address["because"]
    assert_equal "DUMMY-LIA-SECURITY-2026-01", ip_address["legal_basis_reference"]
    assert_equal "security_evidence_retention_ends", ip_address["retain_until_rule"]
    assert ip_address["encrypted"]

    # The retention class's own rule is read back as what it is — a named host
    # calculation — together with whether anything is currently registered to
    # answer it. An unregistered name is the difference between "not due yet"
    # and "nothing can ever say when".
    assert_equal({ "kind" => "host_event",
                   "host_event" => "security_evidence_retention_ends",
                   "calculation_is_registered" => true },
                 ip_address["retention_class_rule"])
    assert_empty inventory["unresolved_host_events"]

    geolocation = regulated["fields"]["ip_geolocation"]
    assert_equal %w[country region city latitude_and_longitude accuracy_radius_in_kilometers],
                 geolocation["fields"]
    assert_equal "DUMMY-DPIA-2026-04", geolocation["data_protection_impact_assessment_reference"]
    assert_equal "Clickwrap::IpGeolocation::StaticResolver", geolocation.dig("resolver", "class")
    assert_equal "2027-08-15", regulated["review_request_evidence_configuration_on"]
    assert_equal 30.days.to_i, regulated["persists_presentations_for_seconds"]

    signup = policy_entry(inventory, "signup")
    assert_not signup["records_any_request_evidence"]
    assert_not signup["fields"]["ip_address"]["recorded"]

    # Where the access decisions live, so a reader knows which file to open.
    assert_not inventory.dig("access_decisions", "authorize_receipt_access_with", "is_clickwrap_default")
    assert_equal 6.years.to_i,
                 inventory["retention_classes"]
                   .find { |klass| klass["retention_class"] == "ordinary_agreement_evidence" }
                   .dig("rules", "core_event", "seconds")
  end

  test "the inventory reports a policy whose review date has already passed" do
    # The date belongs to the host; the inventory states it rather than judging
    # it. What makes the fact actionable is that it is printed at all — the
    # doctor is what turns the same date into a warning.
    travel_to Date.new(2028, 1, 1) do
      regulated = policy_entry(Clickwrap::Privacy.inventory, "regulated_authorization")
      review_on = Date.parse(regulated["review_request_evidence_configuration_on"])

      assert_operator review_on, :<, Date.current,
                      "the fixture's review date must be in the past for this test to mean anything"

      warning = Clickwrap::Doctor.new.report.find do |finding|
        finding.warning? && finding.message.include?("regulated_authorization")
      end

      assert warning, "a review date that has passed must be visible to an operator"
      assert_match(/that date has passed/, warning.message)
    end
  end

  test "an unregistered host calculation is reported rather than smoothed over" do
    Clickwrap.reset!
    Clickwrap.configure(&ActiveSupport::TestCase::DUMMY_CONFIGURATION)
    Clickwrap.retention(:orphaned_evidence) { retain_core_event_until :a_host_event_nobody_registered }

    inventory = Clickwrap::Privacy.inventory
    rule = inventory["retention_classes"]
           .find { |klass| klass["retention_class"] == "orphaned_evidence" }
           .dig("rules", "core_event")

    # "Nothing can ever say when this is due" is a configuration fact worth
    # printing, and printing it is the only way anyone finds out before a
    # disposition run reports the whole class as unresolvable.
    assert_equal false, rule["calculation_is_registered"]
    assert_includes inventory["unresolved_host_events"], "a_host_event_nobody_registered"
  end

  test "the inventory never prints a phrase that would overclaim what any of this proves" do
    printed = JSON.generate(Clickwrap::Privacy.inventory).downcase

    Clickwrap::Vocabulary::PROHIBITED_CLAIM_PHRASES.each do |phrase|
      assert_not_includes printed, phrase,
                          "the inventory printed #{phrase.inspect}, which claims more than a " \
                          "description of a configuration can support"
    end

    assert_match(/does not assess whether any of them is lawful/, Clickwrap::Privacy.inventory["means"])
  end

  # --- Exporting one actor's evidence ----------------------------------------

  test "an actor export uses the same authorization and redaction rules as a receipt export" do
    configure_static_resolver!
    withdrawal = create_withdrawal(user: @user)
    capture_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
                                                http_request: fake_http_request,
                                                answers: { regulated_action: "1" })

    redacted = Clickwrap::Privacy.export_for(@user, requested_by: @user)

    assert_equal @user.clickwrap_actor_reference, redacted["actor_reference"]
    assert_equal 1, redacted["receipt_count"]
    assert_equal "redacted_for_this_viewer",
                 redacted["receipts"].first.dig("request_evidence", "ip_address", "state")
    assert_equal "regulated_action", redacted["current_statements"].first["statement"]

    # There is deliberately no privacy-flavored shortcut that reveals more than
    # `Clickwrap.export_receipt` would: the same callback declines the same
    # caller here.
    assert_raises(Clickwrap::AccessNotAuthorized) do
      Clickwrap::Privacy.export_for(@user, requested_by: @user, because: "Reading my own file",
                                           include_ip_address: true)
    end

    exported = Clickwrap::Privacy.export_for(@user, requested_by: @operator,
                                                    because: "Investigating dispute 2026-184",
                                                    include_ip_address: true)
    ip_address = exported["receipts"].first.dig("request_evidence", "ip_address")

    assert_equal "recorded", ip_address["state"]
    assert_equal "203.0.113.7", ip_address["value"]
  end

  test "an export is keyed by the actor reference, which outlives the account row" do
    capture_clickwrap(:signup, actor: @user)
    reference = @user.clickwrap_actor_reference
    @user.destroy

    exported = Clickwrap::Privacy.export_for(reference, requested_by: @operator)

    # Evidence is keyed by the reference precisely so deleting an account does
    # not delete the record that the account agreed to something.
    assert_equal 1, exported["receipt_count"]
    assert_equal reference, exported["actor_reference"]

    error = assert_raises(ArgumentError) { Clickwrap::Privacy.export_for(nil, requested_by: @operator) }
    assert_match(/needs an actor/, error.message)
  end

  # --- Planning a disposition for one actor ----------------------------------

  test "planning an actor's disposition writes a reviewable plan and deletes nothing" do
    configure_static_resolver!
    withdrawal = create_withdrawal(user: @user)
    receipt = capture_clickwrap(:regulated_authorization, actor: @user, subject: withdrawal,
                                                          http_request: fake_http_request,
                                                          answers: { regulated_action: "1" })
    held = capture_clickwrap(:signup, actor: @user)
    held.place_on_legal_hold!(because: "Pending dispute 2026-184", placed_by: @operator,
                              review_on: 6.months.from_now)

    plan = Clickwrap::Privacy.plan_disposition_for(@user, requested_by: @operator,
                                                          because: "Verified erasure request DSAR-2026-41")
    summary = plan.summary.to_h
    items = plan.scope.to_h["items"]

    assert_equal "actor_privacy", plan.kind
    assert_equal "Verified erasure request DSAR-2026-41", plan.reason
    assert_equal @operator.clickwrap_actor_reference, plan.created_by_reference

    # Each item says what the reviewer would be overriding, and is marked as an
    # actor request rather than a retention item, because the applier re-checks
    # those two for different things.
    assert items.all? { |item| item["eligibility"] == "actor_request" }
    assert_includes items.map { |item| item["event_id"] }, receipt.event_id
    assert_operator summary["still_within_retention_period"], :>=, 1
    assert_match(/Still inside its retention period/, items.first["detail"])

    # The held event is excluded and reported, not quietly dropped.
    assert_not_includes items.map { |item| item["event_id"] }, held.event_id
    assert_equal 1, summary["held"]
    assert_match(/does not decide whether an erasure request overrides a retention/, summary["means"])

    # And nothing at all has happened to the evidence.
    assert Clickwrap::Event.exists?(id: receipt.event_id)
    assert receipt.event.reload.request_evidence.recorded_ip_address?
    assert_not receipt.event.disposed?
  end

  test "planning an actor's disposition needs a reason naming the request it answers" do
    capture_clickwrap(:signup, actor: @user)

    error = assert_raises(Clickwrap::LifecycleError) do
      Clickwrap::Privacy.plan_disposition_for(@user, requested_by: @operator, because: "  ")
    end

    # The reason is what tells the next reviewer why somebody proposed deleting
    # this, and there is nowhere else for it to be recorded.
    assert_match(/naming the request it answers/, error.message)
    assert_equal 0, Clickwrap::DispositionPlan.count
  end

  private

  def policy_entry(inventory, key)
    inventory["policies"].find { |policy| policy["policy"] == key }
  end

  def configure_static_resolver!
    Clickwrap.config.ip_geolocation_resolver = Clickwrap::IpGeolocation::StaticResolver.new(
      "203.0.113.7" => {
        country_code: "ES", country_name: "Spain", region_name: "Madrid", region_code: "MD",
        city_name: "Madrid", postal_code: "28001", latitude: 40.4168, longitude: -3.7038,
        timezone: "Europe/Madrid", continent_code: "EU", accuracy_radius_in_kilometers: 20,
        provider_name: "static_test_resolver", provider_source: "fixture", estimated: true
      }
    )
  end

  def fake_http_request
    ActionDispatch::TestRequest.create(
      "REMOTE_ADDR" => "203.0.113.7",
      "HTTP_USER_AGENT" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Test/1.0",
      "action_dispatch.request_id" => "req-#{SecureRandom.hex(4)}"
    )
  end
end
