# frozen_string_literal: true

require "test_helper"

# Regressions from the 2026-08-16 adversarial review of the hardening pass.
# Each test pins a confirmed defect whose pattern was "the mechanism was built
# correctly and then not carried to every path" — so each asserts the path
# that had been missed, not the one that already worked.
class ReviewRegressionsTest < ActiveSupport::TestCase
  setup { @user = create_user }

  test "consent granted personally stays withdrawable when an ambient organization appears" do
    capture_clickwrap(:personal_newsletter, actor: @user, answers: { personal_newsletter: "1" })
    assert @user.clickwraps.consented_to?(:personal_newsletter)

    # The withdrawing session has an ambient organization (the person joined
    # one after granting). The policy says `tenant_is :not_applicable`, so the
    # grant lives at a nil tenant — and the ambient value must be translated
    # through the policy's own semantics, not compared raw, or the consent
    # becomes permanently unwithdrawable the moment they join.
    ambient_organization = "gid://dummy/Organization/123"

    Clickwrap.withdraw!(
      :personal_newsletter,
      actor: @user,
      tenant: ambient_organization,
      because: "Withdrawn from a session where an organization was current"
    )

    assert_not @user.clickwraps.consented_to?(:personal_newsletter)
  end

  test "a quarantined import stays quarantined through a projection rebuild" do
    result = Clickwrap.import_legacy!(
      :personal_newsletter,
      actor: @user,
      statements: %w[personal_newsletter],
      occurred_at: 1.year.ago,
      known: { "source_flag" => "bundled checkbox" },
      unknown: %i[presentation assertion],
      because: "Imported pending counsel review of the bundled consent",
      counts_as_current: false
    )

    assert_not @user.clickwraps.consented_to?(:personal_newsletter),
               "a counts_as_current: false import must not create a live grant"

    # The laundering path: a projection rebuild replays every initial event.
    # The quarantine decision travels inside the event's structured provenance
    # and must survive the replay — otherwise consent the host explicitly
    # declined to honour starts authorizing processing.
    Clickwrap::CurrentState.rebuild_for!(actor_reference: result.event.actor_reference)

    assert_not @user.clickwraps.consented_to?(:personal_newsletter),
               "rebuild_for! must not launder a quarantined import into an active grant"
  end

  test "an exemption recorded with an Active Record tenant is findable again" do
    tenant = create_user # any AR record works as a tenant reference

    event = Clickwrap.exempt!(
      :seeded_signup,
      actor: Clickwrap.system_actor("database_seed"),
      tenant: tenant,
      because: "Seeded account created before any human could act"
    )

    # `to_s` on an Active Record object is a per-process memory address; the
    # reference must be the stable GID every reader normalizes to, or the
    # exemption can never be matched to a later query for the same tenant.
    assert_equal tenant.to_gid.to_s, event.tenant_key
  end

  test "the document-navigation hook cannot smuggle an href under any capitalization" do
    Clickwrap.config.document_link_html_options_with = ->(_document) { { "HREF" => "/mutable/terms" } }

    presentation = Clickwrap.present(:signup, actor: @user, submit_button_text: "Create account")
    statement = presentation.statements.first

    view = Class.new { include Clickwrap::ViewHelpers }.new
    error = assert_raises(Clickwrap::ConfigurationError) do
      view.clickwrap_document_link_html_options(statement.documents.first)
    end

    # HTML lowercases attribute names and keeps the FIRST duplicate, so a
    # smuggled "HREF" would beat the signed immutable path in the browser.
    assert_match(/cannot set href/, error.message)
  end

  test "an answer longer than any declared choice is refused, never recorded" do
    presentation = present_clickwrap(:signup, actor: @user)

    error = assert_raises(Clickwrap::SubmissionInvalid) do
      submission_for(presentation, terms: "x" * 5_000, privacy_notice: "1")
    end

    assert_match(/never free text/, error.message)
  end
end
