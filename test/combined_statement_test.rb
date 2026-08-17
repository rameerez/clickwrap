# frozen_string_literal: true

require "test_helper"

# A signup screen asks for two ordinary things and used to spend two checkboxes,
# two "Required" flags, two version labels, and two "(opens in a new tab)" hints
# saying so. It now says it in one line:
#
#   [ ] I agree to the Terms of Service and I acknowledge the Privacy Policy.
#
# The interesting half of that is what did NOT collapse. The evidence still
# records two statements with two kinds and two lifecycles, and the sentence
# refuses to absorb anything it cannot honestly say — an optional consent, a
# recorded yes/no, copy the application wrote itself, a purpose someone can
# withdraw. These tests are about that line: what goes into it, what stays out
# of it by construction, and what the composed offer says about itself.
class CombinedStatementTest < ActiveSupport::TestCase
  setup { @user = create_user }

  # --- What composes -----------------------------------------------------------

  test "two ordinary statements compose into one sentence with the documents inside it" do
    combined = Clickwrap.present(:signup, actor: @user).combined

    assert_equal "I agree to the Terms of Service and I acknowledge the Privacy Policy.",
                 combined.sentence
    assert_equal %w[terms privacy_notice], combined.statement_keys

    # The links live in the middle of the sentence, so the fragments are kept
    # split around where they go rather than as text with a placeholder in it.
    assert_equal ["I agree to the ", "I acknowledge the "], combined.fragments.map(&:prefix)
    assert_equal ["", ""], combined.fragments.map(&:suffix)
    assert_equal([["/terms-of-service"], ["/privacy-policy"]],
                 combined.fragments.map { |fragment| fragment.documents.map(&:path) })
  end

  test "the statements the line covers keep their own kinds and their own assertions" do
    presentation = Clickwrap.present(:signup, actor: @user)

    assert_equal %w[agreement acknowledgment], presentation.statements.map(&:kind)
    assert_equal ["I agree to the Terms.", "I acknowledge the Privacy Notice."],
                 presentation.statements.map(&:assertion)
    assert_empty presentation.itemized_statements
  end

  test "the single control is submitted under the first covered statement's name" do
    combined = Clickwrap.present(:signup, actor: @user).combined

    assert_equal "clickwrap_submission[answers][terms]", combined.control_name
    assert_equal "clickwrap_signup_terms", combined.control_id
    assert_equal "terms", combined.answered_as
    assert combined.covers?("privacy_notice")
  end

  test "one statement naming two documents joins them inside its own fragment" do
    Clickwrap.document(:schedules, version: "2026-08-15", content: "Schedules.", link: "/schedules")
    Clickwrap.publish!
    Clickwrap.policy :two_document_terms do
      agree_to :terms, document: %i[terms schedules],
                       link_label: { terms: "Terms of Service", schedules: "Schedules" }
      retain_with :ordinary_agreement_evidence
    end

    combined = Clickwrap.present(:two_document_terms, actor: @user).combined

    assert_equal "I agree to the Terms of Service and the Schedules.", combined.sentence
  end

  # --- What stays out of the line, by construction ------------------------------

  test "an optional consent can never be bundled into the line" do
    Clickwrap.policy :signup_with_marketing do
      agree_to :terms, link_label: "Terms of Service"
      acknowledge :privacy_notice, link_label: "Privacy Policy"
      consent_to :product_updates,
                 document: :marketing_notice,
                 statement: "I agree to receive product update emails.",
                 optional: true,
                 withdrawal_path: "/settings/privacy"
      retain_with :ordinary_agreement_evidence
    end

    presentation = Clickwrap.present(:signup_with_marketing, actor: @user)

    # Not "the linter warns about it" and not "the default happens to exclude
    # it": there is no arrangement of a consent statement that satisfies the
    # composability rule. Unbundled consent is the requirement; this is where
    # the code stops it being possible to get wrong.
    assert_equal %w[terms privacy_notice], presentation.combined.statement_keys
    assert_equal ["product_updates"], presentation.itemized_statements.map(&:key)
    refute presentation.combined.covers?("product_updates")
  end

  test "a consent stays out of the line even when everything else about it would qualify" do
    # Required, checkbox, a document, and the conventional wording — the only
    # thing left is its kind, and its kind is the answer.
    Clickwrap.policy :required_consent do
      consent_to :marketing_notice,
                 statement: "I agree to receive product update emails.",
                 withdrawal_path: "/settings/privacy"
      retain_with :marketing_consent_evidence
    end

    assert_nil Clickwrap.present(:required_consent, actor: @user).combined
  end

  test "copy an application wrote itself gets its own control and its own sentence" do
    Clickwrap.policy :custom_signup do
      agree_to :terms, statement: "I have read and accept the Terms of Service."
      acknowledge :privacy_notice, link_label: "Privacy Policy"
      retain_with :ordinary_agreement_evidence
    end

    presentation = Clickwrap.present(:custom_signup, actor: @user)

    assert_equal ["privacy_notice"], presentation.combined.statement_keys
    assert_equal ["terms"], presentation.itemized_statements.map(&:key)
  end

  test "a recorded yes/no, a declaration, and an attestation never compose" do
    assert_nil Clickwrap.present(:research_contact, actor: @user).combined
    assert_nil Clickwrap.present(:contractor_declaration, actor: @user,
                                                          subject: create_withdrawal(user: @user)).combined
    assert_nil Clickwrap.present(:manual_bank_transfer, actor: @user, capture_channel: :operator).combined
  end

  test "a high-stakes multi-assertion policy is untouched" do
    presentation = Clickwrap.present(:withdrawal_authorization, actor: @user,
                                                                subject: create_withdrawal(user: @user))

    assert_nil presentation.combined
    assert_equal presentation.statements, presentation.itemized_statements
  end

  # --- What the offer signs about itself ------------------------------------------

  test "the manifest signs the sentence, the keys one answer covers, and the link paths" do
    manifest = Clickwrap.present(:signup, actor: @user).manifest

    # The substitution defense has to hold over the sentence a person actually
    # saw, not over two assertions they were never shown separately.
    assert_equal "I agree to the Terms of Service and I acknowledge the Privacy Policy.",
                 manifest.combined_sentence
    assert_equal %w[terms privacy_notice], manifest.combined_statement_keys
    assert_equal "terms", manifest.combined_answered_as
    assert_equal "clickwrap_submission[answers][terms]", manifest.combined_control["control_name"]

    # And the documents inside that sentence are the ones it signs per statement,
    # at the paths it rendered.
    signed_paths = manifest.statements.flat_map do |statement|
      statement["documents"].map { |document| document["path"] }
    end
    assert_equal ["/terms-of-service", "/privacy-policy"], signed_paths
  end

  test "an itemized manifest is byte-identical to the ones this gem has always written" do
    itemized = Clickwrap.present(:signup, actor: @user, combined: false).manifest

    assert_nil itemized.combined_control
    refute_includes itemized.to_h.keys, "combined_control"
    assert_empty itemized.combined_statement_keys
  end

  # --- What one answer records ------------------------------------------------------

  test "one ticked control records both acts, each with its own kind and documents" do
    receipt = submit_clickwrap(:signup, actor: @user, answers: { terms: "1" })

    assert_equal %w[terms privacy_notice], receipt.statements.map(&:statement_key)
    assert_equal %w[agreement acknowledgment], receipt.statements.map(&:kind)
    assert_equal %w[agreed acknowledged], receipt.statements.map(&:action)
    assert(receipt.statements.all?(&:answered))
    assert_equal ["I agree to the Terms.", "I acknowledge the Privacy Notice."],
                 receipt.statements.map(&:assertion_text)

    assert @user.clickwraps.agreed_to?(:terms)
    assert @user.clickwraps.acknowledged?(:privacy_notice)
  end

  test "an unticked control refuses every act the sentence named" do
    presentation = present_clickwrap(:signup, actor: @user)

    error = assert_raises(Clickwrap::AnswerInvalid) do
      Clickwrap.capture!(:signup, actor: @user,
                                  submission: submission_for(presentation, { "terms" => "0" }))
    end

    assert_equal :missing_answer, error.reason
    assert_no_clickwrap_event :signup, actor: @user
    refute @user.clickwraps.acknowledged?(:privacy_notice)
  end

  test "an absent control refuses every act the sentence named" do
    presentation = present_clickwrap(:signup, actor: @user)

    assert_raises(Clickwrap::AnswerInvalid) do
      Clickwrap.capture!(:signup, actor: @user, submission: submission_for(presentation, {}))
    end

    assert_no_clickwrap_event :signup, actor: @user
  end

  test "a hand-posted half-consent is overwritten by the one control the server signed" do
    # The line said both. A submission that ticks the control and then says "but
    # not the privacy notice" is answering a question this page never asked, and
    # the server answers every covered statement from the one box regardless.
    receipt = submit_clickwrap(:signup, actor: @user,
                                        answers: { terms: "1", privacy_notice: "0" })

    assert_equal %w[agreed acknowledged], receipt.statements.map(&:action)
    assert(receipt.statements.all?(&:answered))

    # And the reverse: answering only a covered statement leaves the one real
    # control unanswered, which refuses everything.
    other = create_user
    presentation = present_clickwrap(:signup, actor: other)

    assert_raises(Clickwrap::AnswerInvalid) do
      Clickwrap.capture!(:signup, actor: other,
                                  submission: submission_for(presentation, { "privacy_notice" => "1" }))
    end
    assert_no_clickwrap_event :signup, actor: other
  end

  test "a single answer may not cover a statement the frozen revision left optional" do
    # Belt and braces over a signed value: the manifest is the server's own, but
    # what licenses one answer becoming several is the frozen revision, so that
    # is what gets asked.
    presentation = present_clickwrap(:signup, actor: @user)
    forged = forged_manifest(presentation) do |attributes|
      attributes["combined_control"]["covers"] = %w[terms privacy_notice unknown_statement]
    end

    error = assert_raises(Clickwrap::PresentationInvalid) do
      Clickwrap.capture!(:signup, actor: @user,
                                  submission: Clickwrap::Submission.new(presentation_token: forged,
                                                                        answers: { "terms" => "1" }))
    end

    assert_match(/does not allow a single answer to cover/, error.message)
  end

  test "the control a combined manifest names must be one of the statements it covers" do
    presentation = present_clickwrap(:signup, actor: @user)
    forged = forged_manifest(presentation) do |attributes|
      attributes["combined_control"]["answered_as"] = "somebody_elses_control"
    end

    assert_raises(Clickwrap::PresentationInvalid) do
      Clickwrap.capture!(:signup, actor: @user,
                                  submission: Clickwrap::Submission.new(presentation_token: forged,
                                                                        answers: { "terms" => "1" }))
    end
  end

  # --- What the receipt says was read ----------------------------------------------

  test "the receipt records the sentence that was read, and still verifies" do
    receipt = submit_clickwrap(:signup, actor: @user, answers: { terms: "1" })
    presentation = receipt.to_h.fetch("presentation")

    # The acts below it say what was recorded. This says what the person read,
    # which is the thing a substitution argument is actually about.
    assert_equal "I agree to the Terms of Service and I acknowledge the Privacy Policy.",
                 presentation["combined_sentence"]
    assert_equal %w[terms privacy_notice], presentation["combined_statements"]

    assert_predicate receipt.verify, :success?
    assert_includes receipt.to_html, "I agree to the Terms of Service and I acknowledge the Privacy Policy."
  end

  test "an itemized receipt carries no composed sentence at all" do
    receipt = submit_clickwrap(:manual_bank_transfer, actor: @user, capture_channel: :operator)
    presentation = receipt.to_h.fetch("presentation")

    refute_includes presentation.keys, "combined_sentence"
    refute_includes presentation.keys, "combined_statements"
    assert_predicate receipt.verify, :success?
  end

  # --- Turning it off ------------------------------------------------------------

  test "combined: false presents the itemized shape for a policy that would compose" do
    presentation = Clickwrap.present(:signup, actor: @user, combined: false)

    assert_nil presentation.combined
    assert_equal %w[terms privacy_notice], presentation.itemized_statements.map(&:key)
  end

  # --- Locale --------------------------------------------------------------------

  test "the sentence is composed in the locale being presented" do
    Clickwrap.document(:terms, version: "2026-08-15", locale: :es, content: "Términos.",
                               link: "/es/terminos")
    Clickwrap.document(:privacy_notice, version: "2026-08-15", locale: :es, content: "Privacidad.",
                                        link: "/es/privacidad")
    Clickwrap.publish!
    Clickwrap.policy :spanish_signup do
      agree_to :terms, statement: { en: "I agree to the Terms.", es: "Acepto los Términos." },
                       link_label: { terms: "los Términos de Servicio" }
      retain_with :ordinary_agreement_evidence
    end

    # Custom wording, so :spanish_signup itemizes — the point here is the
    # default-worded :signup policy in Spanish.
    assert_nil Clickwrap.present(:spanish_signup, actor: @user, locale: :es).combined

    combined = Clickwrap.present(:signup, actor: @user, locale: :es).combined
    assert_equal "Acepto Terms of Service y He recibido Privacy Policy.", combined.sentence
  end

  test "a locale with no connective words itemizes rather than composing half a sentence" do
    # Half an English sentence in somebody else's language is worse than two
    # tidy lines in their own, so an untranslated locale falls back to the
    # itemized shape rather than to English glue.
    I18n.available_locales += [:xx]
    I18n.backend.store_translations(:xx, clickwrap: { statements: {
                                      agreement: { terms: "I agree to the Terms." },
                                      acknowledgment: { privacy_notice: "I acknowledge the Privacy Notice." }
                                    } })
    Clickwrap.document(:terms, version: "2026-08-15", locale: :xx, content: "Terms.")
    Clickwrap.document(:privacy_notice, version: "2026-08-15", locale: :xx, content: "Privacy.")
    Clickwrap.publish!

    assert_nil Clickwrap.present(:signup, actor: @user, locale: :xx).combined
  ensure
    I18n.available_locales -= [:xx]
    I18n.backend.reload!
  end

  test "a fragment with nowhere to put its documents itemizes rather than dropping them" do
    I18n.backend.store_translations(:en, clickwrap: { sentence: { acknowledgment: "I acknowledge it" } })

    assert_nil Clickwrap.present(:signup, actor: @user).combined
  ensure
    I18n.backend.reload!
  end

  private

  # Re-signs a presentation's manifest after editing it, so a test can ask what
  # the verifier does with a combined shape the presenter would never build.
  def forged_manifest(presentation)
    attributes = Marshal.load(Marshal.dump(presentation.manifest.to_h))
    yield attributes
    Clickwrap::PresentationManifest.new(attributes).to_token
  end
end
