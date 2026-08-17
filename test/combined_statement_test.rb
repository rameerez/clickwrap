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
end
