# frozen_string_literal: true

require "test_helper"

# The linter is a set of heuristics that warn. It never raises, never blocks a
# render, and — the part these tests exist to hold in place — never certifies
# anything. A clean run means "none of the specific hazards below were detected
# in what was inspected", and the last test here is what stops that from ever
# quietly becoming a stronger claim.
class LinterTest < ActionView::TestCase
  setup do
    @user = create_user
  end

  # --- What it notices ---------------------------------------------------------

  test "it flags a consent control that arrives already selected" do
    findings = Clickwrap::Linter.review_rendered_html(<<~HTML)
      <div class="clickwrap-statement">
        <input type="checkbox" name="clickwrap_submission[answers][product_updates]" checked="checked">
        <label>I agree to receive product update emails.</label>
      </div>
    HTML

    assert_equal [:consent_control_preselected], findings.map(&:code)
    assert_equal "product_updates", findings.first.context[:statement]
    # A pre-ticked box records the page's default, not a person's action.
    assert_match(/records the page's default rather than a person's action/, findings.first.explanation)
  end

  test "it does not mistake a neighbouring element's checked attribute for a preselected control" do
    findings = Clickwrap::Linter.review_rendered_html(<<~HTML)
      <input type="checkbox" name="marketing_opt_in" checked="checked">
      <input type="checkbox" name="clickwrap_submission[answers][product_updates]">
    HTML

    # The host's own unrelated checkbox is the host's business. A linter that
    # cried wolf about it would get switched off, and then it notices nothing.
    assert_empty findings
  end

  test "it flags a consent statement that carries more than one purpose" do
    Clickwrap.policy :bundled_marketing_linter_test do
      consent_to :everything,
                 document: %i[marketing_notice privacy_notice],
                 statement: "I agree to marketing emails and to sharing my details with partners.",
                 optional: true,
                 withdrawal_path: "/settings/privacy"

      retain_with :marketing_consent_evidence
    end

    findings = Clickwrap::Linter.review_policy(Clickwrap.policy!(:bundled_marketing_linter_test))

    assert_equal [:consent_statement_bundles_purposes], findings.map(&:code)
    # One control per purpose is what keeps each grant separately withdrawable —
    # and keeps the receipt able to say which purpose was actually agreed to.
    assert_match(/it presents 2 documents/, findings.first.explanation)
    assert_match(/joins more than one thing with a conjunction/, findings.first.explanation)
  end

  test "it flags a statement the person is asked to accept with nothing to read" do
    Clickwrap.policy :undocumented_linter_test do
      agree_to :house_rules, document: [], statement: "I agree to the house rules."

      retain_with :ordinary_agreement_evidence
    end

    presentation = present_clickwrap(:undocumented_linter_test, actor: @user)
    findings = Clickwrap::Linter.review_presentation(presentation)

    assert_equal [:document_link_missing], findings.map(&:code)
    assert_match(/asked to accept something the page never shows them/, findings.first.explanation)
  end

  test "it flags a document that is part of a statement but was never linked in the markup" do
    presentation = present_clickwrap(:signup, actor: @user)

    findings = Clickwrap::Linter.review_rendered_html(
      %(<input type="checkbox" name="clickwrap_submission[answers][terms]">), presentation: presentation
    )

    unreachable = findings.map { |finding| finding.context[:document] }

    assert_equal [:document_link_missing], findings.map(&:code).uniq
    assert_equal %w[terms privacy_notice], unreachable
  end

  test "it flags a submit control that appears before the clickwrap block" do
    findings = Clickwrap::Linter.review_rendered_html(<<~HTML)
      <button type="submit">Create account</button>
      <input type="hidden" name="clickwrap_submission[presentation_token]" value="…">
      <input type="checkbox" name="clickwrap_submission[answers][terms]">
    HTML

    assert_equal [:submit_control_before_clickwrap_block], findings.map(&:code)
    # Someone can reach the action without having passed what they are being
    # asked to accept.
    assert_match(/without having passed what they are being asked to accept/, findings.first.explanation)
  end

  test "it flags a submitted manifest whose wording no longer matches the policy" do
    presentation = present_clickwrap(:signup, actor: @user)
    reworded = with_statements(presentation) do |statement|
      statement["key"] == "terms" ? statement.merge("assertion" => "I agree to whatever.") : statement
    end

    findings = Clickwrap::Linter.review_manifest(reworded, policy: Clickwrap.policy!(:signup))

    assert_equal [:rendered_manifest_differs_from_policy], findings.map(&:code)
    assert_match(/terms was presented with different wording/, findings.first.explanation)
  end

  test "it flags a submitted manifest that left a statement out entirely" do
    presentation = present_clickwrap(:signup, actor: @user)
    incomplete = with_statements(presentation) { |statement| statement["key"] == "terms" ? statement : nil }

    findings = Clickwrap::Linter.review_manifest(incomplete, policy: Clickwrap.policy!(:signup))

    assert_match(/privacy_notice is in the policy but was not presented/, findings.first.explanation)
  end

  # --- What it stays quiet about ----------------------------------------------

  test "the reference render produces no findings at all" do
    presentation = present_clickwrap(:signup, actor: @user, submit_button_text: "Create account")
    html = render partial: "clickwrap/shared/fields",
                  locals: { presentation: presentation, errors: {}, wrapper_options: {},
                            submit: { text: "Create account", options: {} } }

    # If this ever starts warning, the partial changed in a way that contradicts
    # the evidence contract it is supposed to demonstrate.
    assert_empty Clickwrap::Linter.review_rendered_html(html, presentation: presentation)
    assert_empty Clickwrap::Linter.review_presentation(presentation)
    assert_empty Clickwrap::Linter.review_policy(Clickwrap.policy!(:signup))
    assert_empty Clickwrap::Linter.review_manifest(presentation.manifest, policy: Clickwrap.policy!(:signup))
  end

  test "every policy the dummy host declares passes the policy review" do
    Clickwrap.policies.each do |policy|
      assert_empty Clickwrap::Linter.review_policy(policy),
                   "#{policy.key} produced lint findings the reference declarations should not"
    end
  end

  test "it runs in development and test and stays out of a production request" do
    assert_predicate Clickwrap::Linter, :enabled?

    Rails.stubs(:env).returns(ActiveSupport::StringInquirer.new("production"))
    # A production request has no business scanning its own HTML on the way out.
    refute_predicate Clickwrap::Linter, :enabled?
  end

  test "reporting a finding logs it and never raises" do
    findings = Clickwrap::Linter.review_rendered_html(
      %(<input type="checkbox" name="clickwrap_submission[answers][terms]" checked>)
    )

    assert_equal findings, Clickwrap::Linter.warn_about(findings, source: "policy signup")
    assert_match(/consent_control_preselected: /, findings.first.to_s)
  end

  # --- What it may never say ---------------------------------------------------

  test "no finding it can produce claims compliance, enforceability, or anything like them" do
    findings = every_finding_the_linter_can_produce

    # Sanity: this is only meaningful if it actually collected the catalogue.
    assert_operator findings.length, :>=, 5
    assert_equal %i[
      consent_control_preselected consent_statement_bundles_purposes document_link_missing
      optional_consent_required_for_another_action rendered_manifest_differs_from_policy
      submit_control_before_clickwrap_block
    ], findings.map(&:code).uniq.sort

    findings.each do |finding|
      text = "#{finding.code} #{finding.explanation}".downcase

      Clickwrap::Vocabulary::PROHIBITED_CLAIM_PHRASES.each do |phrase|
        refute_includes text, phrase, "#{finding.code} claims #{phrase.inspect}"
      end

      # Courts assess the complete page in context. No library that has seen one
      # fragment of one template gets to use either of these words.
      refute_match(/complian/, text, "#{finding.code} used a form of \"compliant\"")
      refute_match(/enforceab/, text, "#{finding.code} used a form of \"enforceable\"")
    end
  end

  private

  # A manifest built from a real presentation with exactly one thing changed, so
  # what the linter reacts to is genuine drift rather than a hand-built fixture.
  def with_statements(presentation, &rewrite)
    attributes = presentation.manifest.to_h
    rewritten = attributes["statements"].filter_map(&rewrite)

    Clickwrap::PresentationManifest.new(attributes.merge("statements" => rewritten))
  end

  # One of every finding this class knows how to emit, collected through the real
  # entry points rather than by instantiating Finding directly — a catalogue built
  # from constructor calls would never notice a new finding somebody added.
  def every_finding_the_linter_can_produce
    presentation = present_clickwrap(:signup, actor: @user)

    Clickwrap.policy :bundled_and_gated_linter_test do
      consent_to :product_updates,
                 document: %i[marketing_notice privacy_notice],
                 statement: "I agree to product updates and to partner offers.",
                 optional: true,
                 withdrawal_path: "/settings/privacy"

      authorize :send_it,
                document: :withdrawal_requirements,
                statement: "I authorize this.",
                one_time: true,
                valid_for: 10.minutes,
                requires: %i[product_updates]

      retain_with :marketing_consent_evidence
    end

    [
      *Clickwrap::Linter.review_policy(Clickwrap.policy!(:bundled_and_gated_linter_test)),
      *Clickwrap::Linter.review_presentation(present_clickwrap(:bundled_and_gated_linter_test, actor: @user)),
      *Clickwrap::Linter.review_rendered_html(<<~HTML, presentation: presentation),
        <button type="submit">Create account</button>
        <input type="checkbox" name="clickwrap_submission[answers][terms]" checked>
      HTML
      *Clickwrap::Linter.review_manifest(
        with_statements(presentation) { |statement| statement.merge("assertion" => "Something else.") },
        policy: Clickwrap.policy!(:signup)
      )
    ]
  end
end
