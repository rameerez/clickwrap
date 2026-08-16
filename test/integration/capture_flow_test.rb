# frozen_string_literal: true

require "test_helper"

# The mounted engine, driven through real requests.
#
# The engine exists so that a required agreement, an expired declaration, or a
# consent someone wants back is resolvable IN PLACE instead of turning into a
# support ticket. Everything here is a claim about that: the screen renders, the
# submission records evidence, a refused submission records nothing, a browser
# cannot choose where it is sent afterwards, a receipt belongs to exactly one
# person, and withdrawal takes one press.
#
# The dummy mounts the engine at "/legal" rather than the README's "/agreements"
# precisely so these paths prove the gem hardcodes no prefix.
class CaptureFlowTest < ActionDispatch::IntegrationTest
  setup do
    @user = create_user
    @other_actor = create_user
  end

  teardown do
    ApplicationController.require_current_terms_everywhere = false
  end

  # --- Completing a policy on the standalone screen ---------------------------

  test "the capture screen renders the policy and records nothing until it is submitted" do
    login_as @user

    assert_no_difference -> { Clickwrap::Event.count } do
      get "/legal/policies/signup"
    end

    assert_response :success
    # A render is not evidence. The offer is signed into a short-lived token and
    # the GET writes no row at all.
    assert_select "input[type=hidden][name='clickwrap_submission[presentation_token]']", count: 1
    assert_select "input[type=checkbox]", count: 2
    refute_match(/\bchecked\b/, response.body)
    assert_no_clickwrap_event :signup, actor: @user
  end

  test "submitting the capture screen records the evidence and returns the person where they were going" do
    login_as @user
    get "/legal/policies/signup", params: { return_to: "/billing" }
    assert_response :success

    post "/legal/policies/signup", params: {
      return_to: "/billing",
      clickwrap_submission: {
        presentation_token: presentation_token,
        answers: { terms: "1", privacy_notice: "1" }
      }
    }

    assert_redirected_to "/billing"
    assert_clickwrap_current :signup, actor: @user
    assert_clickwrap_agreed_to :terms, actor: @user
    assert_clickwrap_acknowledged :privacy_notice, actor: @user

    event = Clickwrap::Event.for_policy(:signup).chronological.last
    assert_equal "capture", event.event_type
    assert_equal "web_browser", event.capture_channel
    assert_clickwrap_receipt_verifies event.receipt
  end

  test "a personal policy ignores ambient organization context on both render and submit" do
    organization = create_organization
    login_as @user, organization: organization

    get "/legal/policies/current_terms"
    manifest = Clickwrap::PresentationManifest.from_token(presentation_token)
    assert_equal "", manifest.tenant_key

    post "/legal/policies/current_terms", params: {
      clickwrap_submission: {
        presentation_token: presentation_token,
        answers: { terms: "1" }
      }
    }

    assert_redirected_to "/legal/"
    assert Clickwrap.current?(:current_terms, actor: @user)
    assert_nil Clickwrap::Event.for_policy(:current_terms).last.tenant_key
  end

  test "clickwrap_submission_params_from reads the rendered form back like a browser would" do
    login_as @user
    get "/legal/policies/signup"
    assert_response :success

    post "/legal/policies/signup", params: {
      **clickwrap_submission_params_from(response)
    }

    assert_clickwrap_current :signup, actor: @user
    assert_clickwrap_agreed_to :terms, actor: @user
    assert_clickwrap_acknowledged :privacy_notice, actor: @user
  end

  test "clickwrap_submission_params_from honors per-statement overrides and refuses a tokenless page" do
    login_as @user
    get "/legal/policies/signup"

    params = clickwrap_submission_params_from(response.body, answers: { terms: false })
    assert_equal "0", params.dig("clickwrap_submission", "answers", "terms")
    assert_equal "1", params.dig("clickwrap_submission", "answers", "privacy_notice")

    error = assert_raises(ArgumentError) { clickwrap_submission_params_from("<html></html>") }
    assert_match(/no clickwrap presentation token/, error.message)
  end

  test "clickwrap_submission_params_from selects one exact form and refuses an ambiguous page" do
    html = <<~HTML
      <form id="first">
        <input name="clickwrap_submission[presentation_token]" value="first-token">
        <input name="clickwrap_submission[answers][first_statement]" type="checkbox">
      </form>
      <form id="second">
        <input name="clickwrap_submission[presentation_token]" value="second-token">
        <input name="clickwrap_submission[answers][second_statement]" type="checkbox">
      </form>
    HTML

    ambiguous = assert_raises(ArgumentError) { clickwrap_submission_params_from(html) }
    assert_match(/2 clickwrap presentation tokens/, ambiguous.message)
    assert_match(/form_css_selector/, ambiguous.message)

    params = clickwrap_submission_params_from(html, form_css_selector: "form#second")
    assert_equal "second-token", params.dig("clickwrap_submission", "presentation_token")
    assert_equal({ "second_statement" => "1" }, params.dig("clickwrap_submission", "answers"))

    missing = assert_raises(ArgumentError) do
      clickwrap_submission_params_from(html, form_css_selector: "form#missing")
    end
    assert_match(/match exactly one <form>/, missing.message)
  end

  test "clickwrap_submission_params_from submits rendered radio choice values instead of checkbox values" do
    html = <<~HTML
      <form id="domain-choices">
        <input name="clickwrap_submission[presentation_token]" value="choice-token">
        <input name="clickwrap_submission[answers][employment_kind]" type="radio" value="employee">
        <input name="clickwrap_submission[answers][employment_kind]" type="radio" value="contractor">
        <input name="clickwrap_submission[answers][newsletter]" type="radio" value="yes">
        <input name="clickwrap_submission[answers][newsletter]" type="radio" value="no">
      </form>
    HTML

    defaults = clickwrap_submission_params_from(html)
    assert_equal "employee", defaults.dig("clickwrap_submission", "answers", "employment_kind")
    assert_equal "yes", defaults.dig("clickwrap_submission", "answers", "newsletter")

    overrides = clickwrap_submission_params_from(
      html,
      answers: { employment_kind: "contractor", newsletter: false }
    )
    assert_equal "contractor", overrides.dig("clickwrap_submission", "answers", "employment_kind")
    assert_equal "no", overrides.dig("clickwrap_submission", "answers", "newsletter")
  end

  test "a required control left unchecked re-renders the screen with an error and records nothing" do
    login_as @user
    get "/legal/policies/signup"

    post "/legal/policies/signup", params: {
      clickwrap_submission: { presentation_token: presentation_token, answers: { terms: "1" } }
    }

    assert_response 422
    # The failed submission re-renders under the address the browser is already
    # on, with the summary a person looking for what went wrong will find first.
    assert_select "div.clickwrap-error-summary[role=alert]"
    assert_select "a[href='#clickwrap_signup_privacy_notice']"

    # And a partial event that later reads as assent is exactly what must not
    # exist here.
    assert_no_clickwrap_event :signup, actor: @user
    refute_predicate Clickwrap.verify(:signup, actor: @user), :success?
  end

  test "a presentation the server cannot verify is offered again rather than repaired quietly" do
    login_as @user
    get "/legal/policies/signup"

    post "/legal/policies/signup", params: {
      clickwrap_submission: {
        presentation_token: "not-a-token-this-server-ever-signed",
        answers: { terms: "1", privacy_notice: "1" }
      }
    }

    # A stale, replayed, or swapped presentation is not something to fix behind
    # the person's back: the server re-offers the policy and they answer the
    # offer they can actually see.
    assert_response 422
    assert_select "p.clickwrap-flash--alert"
    assert_no_clickwrap_event :signup, actor: @user
  end

  test "malformed submission envelopes are refused as input errors instead of crashing" do
    login_as @user

    ["not-an-object", %w[not an object]].each do |malformed|
      assert_no_difference -> { Clickwrap::Event.count } do
        post "/legal/policies/signup", params: { clickwrap_submission: malformed }
      end

      assert_response :unprocessable_entity
      assert_select "p.clickwrap-flash--alert"
    end
  end

  test "a malformed answers value is refused as an input error instead of crashing" do
    login_as @user
    get "/legal/policies/signup"

    assert_no_difference -> { Clickwrap::Event.count } do
      post "/legal/policies/signup", params: {
        clickwrap_submission: {
          presentation_token: presentation_token,
          answers: "not-an-object"
        }
      }
    end

    assert_response :unprocessable_entity
  end

  test "a changed replay is offered a fresh presentation instead of becoming a server error" do
    login_as @user
    get "/legal/policies/signup"
    token = presentation_token

    post "/legal/policies/signup", params: {
      clickwrap_submission: {
        presentation_token: token,
        answers: { terms: "1", privacy_notice: "1" }
      }
    }
    assert_redirected_to "/legal/"

    assert_no_difference -> { Clickwrap::Event.count } do
      post "/legal/policies/signup", params: {
        clickwrap_submission: {
          presentation_token: token,
          answers: { terms: "true", privacy_notice: "true" }
        }
      }
    end

    assert_response :unprocessable_entity
    assert_select "input[name='clickwrap_submission[presentation_token]']"
  end

  test "the standalone capture screen answers an unauthenticated request without crashing" do
    get "/legal/policies/signup"

    assert_response :unauthorized
  end

  test "receipt and consent-withdrawal screens require a real current actor" do
    receipt = capture_clickwrap(:signup, actor: @user)

    get "/legal/receipts/#{receipt.event_id}"
    assert_response :unauthorized

    get "/legal/consents/product_updates/withdrawal"
    assert_response :unauthorized
  end

  test "a policy this application does not declare is not found" do
    login_as @user

    get "/legal/policies/no_such_policy"

    assert_response :not_found
  end

  test "a return_to pointing off this host is refused rather than repaired" do
    login_as @user
    get "/legal/policies/signup"

    post "/legal/policies/signup", params: {
      return_to: "https://evil.example/steal",
      clickwrap_submission: {
        presentation_token: presentation_token,
        answers: { terms: "1", privacy_notice: "1" }
      }
    }

    # Return-to values arrive from the browser, so they are untrusted navigation
    # input: anything that is not a relative path on this host falls back to the
    # engine's own root instead of being made to look close enough.
    assert_redirected_to "/legal/"
    assert_clickwrap_current :signup, actor: @user
  end

  test "a return_to is only honoured when it is a relative path on this host" do
    login_as @user

    ["https://evil.example/steal", "//evil.example/steal", "/\\evil.example",
     "javascript:alert(1)", "not-a-path", "/billing\nHeader: injected", ""].each do |candidate|
      get "/legal/policies/signup", params: { return_to: candidate }

      assert_response :success
      # Anything with a scheme, a host, a protocol-relative prefix, or a control
      # character falls back to this engine's own root. Nothing is "repaired"
      # into something that looks close enough.
      assert_equal "/legal/", css_select("input[name=return_to]").first["value"],
                   "#{candidate.inspect} should not have survived as a destination"
    end

    get "/legal/policies/signup", params: { return_to: "/billing" }
    assert_equal "/billing", css_select("input[name=return_to]").first["value"]
  end

  # --- Reading a document ------------------------------------------------------

  test "a document link serves the exact rendered snapshot under its recorded media type" do
    version = published_version_of(:terms)

    get "/legal/documents/#{version.id}"

    assert_response :success
    assert_equal version.rendered_bytes, response.body
    assert_equal "text/html", response.media_type
    # The rendered snapshot is inert, tightly sandboxed markup rather than a
    # page that can inherit the host application's capabilities.
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert_includes response.headers["Content-Security-Policy"], "sandbox"
  end

  test "a published document is readable before anyone is signed in" do
    # The signup form links to it, and that is the moment it matters most.
    get "/legal/documents/#{published_version_of(:privacy_notice).id}"

    assert_response :success
    assert_includes response.body, "privacy"
  end

  test "an unknown document version is not found" do
    get "/legal/documents/999999999"

    assert_response :not_found
  end

  test "a document whose stored bytes no longer match their digest is refused, never served" do
    version = published_version_of(:terms)
    # `update_column` is how this could actually happen: a console session or a
    # data-fix script going around the model's own refusal to edit published
    # content.
    version.update_column(:content, "#{version.content}\n\nquietly edited later")

    get "/legal/documents/#{version.id}"

    # Serving them anyway would turn this action into a way to launder changed
    # content into an old agreement, which is the one thing it must never do.
    assert_response 422
    refute_includes response.body, "quietly edited later"
  end

  # --- Reading a receipt -------------------------------------------------------

  test "an actor can read their own receipt" do
    receipt = capture_clickwrap(:signup, actor: @user)
    login_as @user

    get "/legal/receipts/#{receipt.event_id}"

    assert_response :success
    assert_includes response.body, receipt.event_id
    assert_includes response.body, "I agree to the Terms."
    # The page says what the record does and does not show, beside the record.
    assert_includes response.body, "It does not show that anyone read or understood"
  end

  test "another actor's receipt is not found rather than forbidden" do
    receipt = capture_clickwrap(:signup, actor: @user)
    login_as @other_actor

    get "/legal/receipts/#{receipt.event_id}"

    # A 403 would tell an outsider that the id they guessed exists, and existence
    # is itself information about someone.
    assert_response :not_found
  end

  test "the receipt list shows the viewer's own records and nobody else's" do
    mine = capture_clickwrap(:signup, actor: @user)
    theirs = capture_clickwrap(:signup, actor: @other_actor)
    login_as @user

    get "/legal/receipts"

    assert_response :success
    assert_includes response.body, mine.event_id,
                    "the viewer's own event is missing from their own list. Recorded actor " \
                    "references: #{Clickwrap::Event.pluck(:actor_reference).inspect}; the viewer's " \
                    "is #{@user.clickwrap_actor_reference.inspect}"
    refute_includes response.body, theirs.event_id
  end

  test "the JSON format returns the canonical receipt verbatim" do
    receipt = capture_clickwrap(:signup, actor: @user)
    login_as @user

    get "/legal/receipts/#{receipt.event_id}.json"

    assert_response :success
    # The canonical bytes are the verifiable artifact, so the endpoint hands back
    # exactly those rather than a re-serialization of them.
    assert_equal Clickwrap.receipt(receipt.event_id).to_canonical_json, response.body
  end

  # --- The gate ----------------------------------------------------------------

  test "a gated page redirects an HTML visitor to the capture screen and back afterwards" do
    login_as @user

    get "/billing"

    assert_equal "/legal/policies/current_terms", remediation_redirect_uri.path
    assert remediation_redirect_token.present?

    capture_clickwrap(:current_terms, actor: @user)
    get "/billing"

    # A gate that blocks an action with no route to unblocking it is a dead end.
    assert_response :success
    assert_equal "billing statement", response.body
  end

  test "an app-wide gate leaves its own remediation and document screens reachable" do
    login_as @user
    ApplicationController.require_current_terms_everywhere = true

    get "/billing"
    assert_equal "/legal/policies/current_terms", remediation_redirect_uri.path

    follow_redirect!
    assert_response :success
    assert_select "input[name='clickwrap_submission[presentation_token]']", count: 1

    terms = published_version_of(:terms)
    get "/legal/documents/#{terms.id}"
    assert_response :success

    get "/legal/policies/current_terms", params: { return_to: "/billing" }
    post "/legal/policies/current_terms", params: {
      return_to: "/billing",
      clickwrap_submission: {
        presentation_token: presentation_token,
        answers: { terms: "1" }
      }
    }

    assert_redirected_to "/billing"
    follow_redirect!
    assert_response :success
    assert_equal "billing statement", response.body
  end

  test "a gated endpoint answers a JSON client with a structured clickwrap_required response" do
    login_as @user

    get "/billing", as: :json

    assert_response :forbidden
    body = JSON.parse(response.body)
    # Something a client can branch on, plus the endpoint that can satisfy it —
    # never an HTML redirect an API client would follow into a login page.
    assert_equal "clickwrap_required", body["error"]
    assert_equal "current_terms", body["policy"]
    uri = URI.parse(body.fetch("presentation_url"))
    assert_equal "/legal/policies/current_terms", uri.path
    assert URI.decode_www_form(uri.query.to_s).to_h.fetch("remediation_token").present?
  end

  test "a signed-out HTML visitor to a host gate receives an HTML-shaped unauthorized response" do
    get "/billing"

    assert_response :unauthorized
    assert_empty response.body
    refute_equal "application/json", response.media_type
  end

  test "a signed-out JSON client to a host gate receives the structured actor-required response" do
    get "/billing", as: :json

    assert_response :unauthorized
    assert_equal({ "error" => "clickwrap_actor_required", "policy" => "current_terms" },
                 JSON.parse(response.body))
  end

  test "a subject-bound gate remediates the exact server-owned subject and returns to the blocked action" do
    withdrawal = create_withdrawal(user: @user)
    login_as @user

    get "/withdrawal_reviews/#{withdrawal.id}"

    token = remediation_redirect_token
    assert_equal "/legal/policies/driver_declaration", remediation_redirect_uri.path

    follow_redirect!
    assert_response :success
    assert_equal token, css_select("input[name=remediation_token]").first["value"]

    post "/legal/policies/driver_declaration", params: {
      remediation_token: token,
      # This browser-owned value conflicts with the signed route and therefore
      # must lose. The server returns to the blocked action in the token.
      return_to: "/billing",
      clickwrap_submission: {
        presentation_token: presentation_token,
        answers: { non_professional_driver: "1" }
      }
    }

    assert_redirected_to "/withdrawal_reviews/#{withdrawal.id}"
    assert Clickwrap.current?(:driver_declaration, actor: @user, subject: withdrawal)

    get "/withdrawal_reviews/#{withdrawal.id}"
    assert_response :success
  end

  test "a subject-bound remediation token cannot be used by another actor" do
    withdrawal = create_withdrawal(user: @user)
    login_as @user
    get "/withdrawal_reviews/#{withdrawal.id}"
    destination = response.location

    login_as @other_actor
    get destination

    assert_response :not_found
    assert_no_clickwrap_event :driver_declaration, actor: @other_actor
  end

  test "a subject-bound gate does not disclose another actor's subject" do
    withdrawal = create_withdrawal(user: @user)
    login_as @other_actor

    get "/withdrawal_reviews/#{withdrawal.id}"

    assert_response :not_found
    assert_no_clickwrap_event :driver_declaration, actor: @other_actor
  end

  test "a remediation token is invalid after its subject changes" do
    withdrawal = create_withdrawal(user: @user)
    login_as @user
    get "/withdrawal_reviews/#{withdrawal.id}"
    destination = response.location

    withdrawal.update!(amount_cents: withdrawal.amount_cents + 1)
    get destination

    assert_response :not_found
    assert_no_clickwrap_event :driver_declaration, actor: @user
  end

  test "a remediation token is invalid after its subject is deleted" do
    withdrawal = create_withdrawal(user: @user)
    login_as @user
    get "/withdrawal_reviews/#{withdrawal.id}"
    destination = response.location

    withdrawal.destroy!
    get destination

    assert_response :not_found
    assert_no_clickwrap_event :driver_declaration, actor: @user
  end

  test "a policy recording representative authority cannot be completed on the bare engine screen" do
    # Without a signed remediation route there is no represented party, so a
    # standalone completion would write permanent evidence whose statements
    # assert authority over nobody — orphan evidence that reads as more than
    # it is.
    Clickwrap.policy :orphan_authority_terms do
      agree_to :terms
      permit_acting_for_organization when_actor_is_at_least: :admin
      retain_with :ordinary_agreement_evidence
    end

    login_as @user

    get "/legal/policies/orphan_authority_terms"
    assert_response :not_found

    assert_no_difference -> { Clickwrap::Event.count } do
      post "/legal/policies/orphan_authority_terms"
    end
    assert_response :not_found
  end

  # --- Withdrawing a consent ---------------------------------------------------

  test "withdrawing a consent takes one press, the same as granting it did" do
    capture_clickwrap(:marketing_preferences, actor: @user, answers: { product_updates: "1" })
    login_as @user

    get "/legal/consents/product_updates/withdrawal"

    assert_response :success
    # One page, one control, one press. Every extra step here would be a step
    # nobody had to take to say yes.
    assert_select "input[type=submit]", count: 1
    assert_select "input[type=text], input[type=password], textarea, select", count: 0

    post "/legal/consents/product_updates/withdrawal"

    assert_redirected_to "/legal/"
    refute @user.clickwraps.consented_to?(:product_updates)
  end

  test "withdrawal appends an event and leaves the historical grant exactly as it was" do
    grant = capture_clickwrap(:marketing_preferences, actor: @user, answers: { product_updates: "1" })
    login_as @user

    post "/legal/consents/product_updates/withdrawal"

    assert Clickwrap::Event.exists?(id: grant.event_id)
    assert_predicate grant.event.reload, :digest_verified?
    assert_equal "withdrawal", Clickwrap::Event.for_actor(@user.clickwrap_actor_reference)
                                               .chronological.last.event_type
  end

  test "pressing withdraw a second time appends nothing and leaves the purpose withdrawn" do
    capture_clickwrap(:marketing_preferences, actor: @user, answers: { product_updates: "1" })
    login_as @user

    post "/legal/consents/product_updates/withdrawal"
    assert_redirected_to "/legal/"

    assert_no_difference -> { Clickwrap::Event.count } do
      post "/legal/consents/product_updates/withdrawal"
    end

    # Pressing the button twice is not an error worth showing a person: the
    # purpose is withdrawn either way, which is exactly what they asked for. So
    # the second press redirects like the first and appends nothing — as
    # distinct from withdrawing something that was never granted, which is a
    # different situation and does get an error.
    assert_redirected_to "/legal/"
    refute @user.clickwraps.consented_to?(:product_updates)
  end

  test "the engine withdraws a consent inside the current tenant instead of searching globally" do
    organization = create_organization
    capture_clickwrap(
      :marketing_preferences,
      actor: @user,
      tenant: organization,
      answers: { product_updates: "1" }
    )
    login_as @user, organization: organization

    post "/legal/consents/product_updates/withdrawal"

    assert_redirected_to "/legal/"
    refute @user.clickwraps.consented_to?(:product_updates, tenant: organization)
  end

  test "withdrawing something that is not withdrawable says so instead of pretending" do
    capture_clickwrap(:signup, actor: @user)
    login_as @user

    post "/legal/consents/terms/withdrawal"

    # Withdrawing future consent never rewrites a past agreement, and the screen
    # says that rather than recording something that did not happen.
    assert_response 422
    assert_clickwrap_agreed_to :terms, actor: @user
  end

  private

  def presentation_token
    css_select("input[name='clickwrap_submission[presentation_token]']").first["value"]
  end

  def published_version_of(document_key)
    Clickwrap::Document.find_by(document_key: document_key.to_s).current_version(locale: "en")
  end

  def remediation_redirect_uri
    URI.parse(response.location)
  end

  def remediation_redirect_token
    URI.decode_www_form(remediation_redirect_uri.query.to_s).to_h.fetch("remediation_token")
  end
end
