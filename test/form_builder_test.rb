# frozen_string_literal: true

require "test_helper"

# `form.clickwrap` is the one line the README leads with, so what it renders is
# part of the product rather than an implementation detail. These tests render it
# through a real ActionView context and assert on the HTML that comes out,
# because every claim below is a claim about what a person actually sees:
# nothing preselected, the sentence beside the control, the document reachable
# before the button, and no server-owned decision sitting in a field a browser
# could edit.
class FormBuilderTest < ActionView::TestCase
  setup do
    @user = create_user
  end

  # --- The reference render ---------------------------------------------------

  test "every control is rendered unchecked, one per statement" do
    render_clickwrap(:signup, submit: "Create account")

    assert_select "input[type=checkbox]", count: 2
    assert_select "input[type=checkbox][name='clickwrap_submission[answers][terms]']", count: 1
    assert_select "input[type=checkbox][name='clickwrap_submission[answers][privacy_notice]']", count: 1

    # Not "no control has checked=true" — no `checked` ANYWHERE in the markup. A
    # pre-ticked box records the page's default rather than a person's action,
    # and there is no version of this partial where one is acceptable.
    refute_match(/\bchecked\b/, rendered)
  end

  test "each control's label carries the exact assertion the receipt will record" do
    render_clickwrap(:signup, submit: "Create account")

    # "agree to the Terms" and "acknowledge the Privacy Notice" are different
    # acts, and the words beside each control are the words the event stores.
    assert_select "label[for=clickwrap_signup_terms]", text: /\AI agree to the Terms\./
    assert_select "label[for=clickwrap_signup_privacy_notice]", text: /\AI acknowledge the Privacy Notice\./
  end

  test "a document link comes before the submit button, names the document, and opens safely" do
    render_clickwrap(:signup, submit: "Create account")

    links = css_select("a.clickwrap-documents__link")
    # The accessible name is the document's own name. "Click here" tells a person
    # reading a link list nothing about what they are about to accept.
    link_texts = links.map { |link| link.text.strip }
    assert_equal ["Terms", "Privacy notice"], link_texts
    links.each do |link|
      assert_equal "noopener", link["rel"]
      assert_equal "_blank", link["target"]
    end

    # A link that only appears after the call to action has been pressed is not a
    # link to anything.
    assert_operator rendered.index("clickwrap-documents__link"), :<,
                    rendered.index(/<input[^>]*type="submit"/),
                    "document links must appear before the submit button in source order"
  end

  test "a host can customize document navigation without ejecting the statement partial" do
    Clickwrap.config.document_link_html_options_with = lambda do |_document|
      { target: "_blank", rel: "noopener", data: { turbo: false, native_document: "external" } }
    end

    render_clickwrap(:signup, submit: "Create account")

    assert_select "a.clickwrap-documents__link[target='_blank'][rel='noopener']" \
                  "[data-turbo='false'][data-native-document='external']", count: 2
  end

  test "document navigation options cannot replace the signed immutable href" do
    Clickwrap.config.document_link_html_options_with = ->(_document) { { href: "/mutable/terms" } }

    error = assert_raises(ActionView::Template::Error) do
      render_clickwrap(:signup, submit: "Create account")
    end

    assert_match(/cannot set href/, error.message)
    assert_match(/immutable document path/, error.message)
  end

  test "the only hidden field is the signed presentation token" do
    render_clickwrap(:signup, submit: "Create account")

    assert_select "input[type=hidden][name='clickwrap_submission[presentation_token]']", count: 1

    # Everything the server decides — the address it observed, the browser string,
    # the estimated location, which policy revision, which document versions, how
    # long the evidence is valid — is resolved server-side and rechecked at
    # submit. A form field is not a safe place to keep a security decision, so
    # there must not be a second hidden field here at all.
    carried = hidden_field_names - %w[authenticity_token utf8 _method]
    assert_equal ["clickwrap_submission[presentation_token]"], carried

    %w[ip_address remote_ip user_agent geolocation latitude longitude
       policy_revision version valid_until expires_at retain_until].each do |server_owned|
      refute_match(/<input[^>]*name="[^"]*#{server_owned}/i, rendered,
                   "a #{server_owned} field would be a server-owned decision the browser could edit")
    end
  end

  test "a required statement's control is marked required" do
    render_clickwrap(:signup, submit: "Create account")

    # `required` is progressive enhancement only. The server decides either way,
    # so a browser that ignores it and a script that posts by hand meet the same
    # check at capture.
    assert_select "input[type=checkbox][required]", count: 2
  end

  test "an optional consent's control is not marked required" do
    render_clickwrap(:marketing_preferences, submit: "Save preferences")

    # Marking an optional marketing consent required would be a lie told by the
    # page itself, and leaving it unselected has to keep creating no grant.
    assert_select "input[type=checkbox]", count: 2
    assert_select "input[type=checkbox][required]", count: 0
    assert_select "span.clickwrap-statement__flag", text: "Optional", count: 2
  end

  test "the call to action recorded in the manifest is the text on the button" do
    render_clickwrap(:signup, submit: "Create account")

    # There is no second place for this string to live, so it cannot drift. The
    # token is decoded rather than re-derived, so this checks the manifest that
    # was actually rendered into the page.
    manifest = Clickwrap::PresentationManifest.from_token(presentation_token)

    assert_equal "Create account", manifest.submit_button_text
    assert_equal "Create account", css_select("input[type=submit]").first["value"]
  end

  test "the submit button accepts host styling without losing the recorded wording" do
    render_clickwrap(:signup, submit: { text: "Create account", class: "btn btn--primary" })

    button = css_select("input[type=submit]").first
    assert_equal "Create account", button["value"]
    assert_includes button["class"], "btn--primary"
    assert_includes button["class"], "clickwrap-submit"
    assert_equal "Create account", Clickwrap::PresentationManifest.from_token(presentation_token).submit_button_text
  end

  test "an explicit capture channel travels into the manifest instead of being assumed" do
    render_clickwrap(:manual_bank_transfer, submit: "Record the transfer", capture_channel: :operator)

    # Where a capture came from is recorded, never guessed. This policy only
    # accepts operator captures, so a default of web_browser would be refused —
    # which is the point: the channel is a declared fact.
    assert_equal "operator", Clickwrap::PresentationManifest.from_token(presentation_token).to_h["capture_channel"]
  end

  # --- An explicit yes/no decision --------------------------------------------

  test "an explicit choice renders every option unselected inside a labelled group" do
    render_clickwrap(:research_contact, submit: "Save")

    radios = css_select("input[type=radio]")
    choices = radios.map { |radio| radio["value"] }

    assert_equal %w[yes no], choices
    radios.each { |radio| assert_nil radio["checked"] }
    refute_match(/\bchecked\b/, rendered)

    # A fieldset and legend, so the sentence is announced with the options rather
    # than leaving "Yes" and "No" floating without their question.
    assert_select "fieldset legend", text: /You may contact me about product research\./
  end

  test "a withdrawable consent renders its withdrawal route on the same screen that grants it" do
    render_clickwrap(:marketing_preferences, submit: "Save preferences")

    # Consent that cannot be withdrawn as easily as it was given is not something
    # this gem will go on calling consent.
    assert_select "a.clickwrap-statement__withdrawal-link[href='/settings/privacy']", count: 2
  end

  # --- The failed submission ---------------------------------------------------

  test "a rejected statement renders its error as text, tied to the control it is about" do
    render_clickwrap(:signup, submit: "Create account",
                              errors: { "terms" => "You need to answer this before continuing." })

    assert_select "input#clickwrap_signup_terms[aria-invalid=true][aria-describedby=clickwrap_signup_terms_error]"

    # The meaning is in the words, not in the color they are printed in: the
    # message is readable text sitting in the element aria-describedby points at.
    assert_select "p#clickwrap_signup_terms_error", text: /You need to answer this before continuing\./

    # And the statement that was accepted is left alone.
    assert_select "input#clickwrap_signup_privacy_notice[aria-invalid]", count: 0
  end

  test "a failed submission renders an announced error summary that links to the failing control" do
    render_clickwrap(:signup, submit: "Create account",
                              errors: { "terms" => "You need to answer this before continuing." })

    assert_select "div.clickwrap-error-summary[role=alert]" do
      assert_select "a[href='#clickwrap_signup_terms']", text: /You need to answer this before continuing\./
    end
  end

  test "an error state still preselects nothing" do
    render_clickwrap(:signup, submit: "Create account",
                              errors: { "terms" => "You need to answer this before continuing." })

    # The tempting bug: re-render the form with the boxes the person did tick
    # already ticked. Clickwrap re-presents instead, so what is captured is
    # always an action taken against the server-generated offer.
    refute_match(/\bchecked\b/, rendered)
  end

  # --- The split API -----------------------------------------------------------

  test "clickwrap_fields renders the controls and the token but leaves the action to the host" do
    render_clickwrap_fields(:signup, submit_button_text: "Create account")

    assert_select "input[type=checkbox]", count: 2
    assert_select "input[type=hidden][name='clickwrap_submission[presentation_token]']", count: 1
    assert_select "input[type=submit]", count: 0

    # The declared wording is still what the manifest records, which is the whole
    # reason the split API asks for it.
    assert_equal "Create account", Clickwrap::PresentationManifest.from_token(presentation_token).submit_button_text
  end

  test "clickwrap_submit reuses the split presentation wording without a second string" do
    render inline: <<~ERB
      <%= form_with url: "/signup", method: :post do |form| %>
        <%= form.clickwrap_fields :signup, actor: @user, submit_button_text: "Create account" %>
        <%= form.clickwrap_submit class: "button" %>
      <% end %>
    ERB

    assert_select "input[type=submit][value='Create account'].button", count: 1
    assert_equal "Create account", Clickwrap::PresentationManifest.from_token(presentation_token).submit_button_text
  end

  test "ordinary form submit refuses wording that differs from the split presentation" do
    error = assert_raises(ActionView::Template::Error) do
      render inline: <<~ERB
        <%= form_with url: "/signup", method: :post do |form| %>
          <%= form.clickwrap_fields :signup, actor: @user, submit_button_text: "Create account" %>
          <%= form.submit "Register" %>
        <% end %>
      ERB
    end

    assert_match(/records "Create account".*rendered "Register"/, error.message)
    assert_match(/form\.clickwrap_submit/, error.message)
  end

  test "the manifest binds the exact immutable document paths rendered by the form" do
    render_clickwrap(:signup, submit: "Create account")

    manifest_paths = Clickwrap::PresentationManifest.from_token(presentation_token).statements.flat_map do |statement|
      Array(statement["documents"]).map { |document| document["path"] }
    end
    rendered_paths = css_select("a.clickwrap-documents__link").map { |link| link["href"] }

    assert_equal rendered_paths, manifest_paths
    assert(manifest_paths.all? { |path| path.match?(%r{/documents/\d+\z}) })
  end

  test "form.clickwrap refuses to guess the call to action" do
    # The manifest records the words the person was offered, so there is nothing
    # sensible to infer here and inferring would put a wrong string in evidence.
    # (ActionView wraps the ArgumentError, as it does for any error in a render.)
    styled_but_unnamed = assert_raises(ActionView::Template::Error) do
      render_clickwrap(:signup, submit: { class: "btn" })
    end
    assert_match(/needs the exact words on the submit button/, styled_but_unnamed.message)

    nothing_at_all = assert_raises(ActionView::Template::Error) { render_clickwrap(:signup, submit: nil) }
    assert_match(/needs `submit:` to be the button text/, nothing_at_all.message)
  end

  test "one Rails form refuses two ambiguous Clickwrap presentation tokens" do
    error = assert_raises(ActionView::Template::Error) do
      render inline: <<~ERB
        <%= form_with url: "/signup", method: :post do |form| %>
          <%= form.clickwrap :current_terms, actor: @user, submit: "Accept terms" %>
          <%= form.clickwrap :signup, actor: @user, submit: "Create account" %>
        <% end %>
      ERB
    end

    assert_match(/only one Clickwrap presentation/, error.message)
    assert_match(/one Clickwrap policy.*separate form/i, error.message)
  end

  private

  # Rendered through an inline template rather than by calling the helper
  # directly, so this goes through a real view context, a real form builder, and
  # the engine's real partial lookup — the same path a host application uses.
  def render_clickwrap(policy_key, submit:, **options)
    locals = { policy_key: policy_key, submit: submit, options: options.merge(actor: @user) }

    render inline: <<~ERB, locals: locals
      <%= form_with url: "/signup", method: :post do |form| %>
        <%= form.clickwrap policy_key, submit: submit, **options %>
      <% end %>
    ERB
  end

  def render_clickwrap_fields(policy_key, submit_button_text:, **options)
    locals = { policy_key: policy_key, text: submit_button_text, options: options.merge(actor: @user) }

    render inline: <<~ERB, locals: locals
      <%= form_with url: "/signup", method: :post do |form| %>
        <%= form.clickwrap_fields policy_key, submit_button_text: text, **options %>
      <% end %>
    ERB
  end

  def hidden_field_names
    css_select("input[type=hidden]").map { |input| input["name"].to_s }
  end

  def presentation_token
    css_select("input[name='clickwrap_submission[presentation_token]']").first["value"]
  end
end
