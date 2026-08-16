# frozen_string_literal: true

require "test_helper"

# The custom-surface helpers own the three contracts a hand-written form gets
# wrong silently: the envelope name, the statement control names/ids, and a
# call to action worded by the signed manifest itself.
class ViewHelpersTest < ActionView::TestCase
  include Clickwrap::ViewHelpers

  setup do
    @user = create_user
    @presentation = Clickwrap.present(
      :signup,
      actor: @user,
      submit_button_text: "Crear cuenta"
    )
  end

  test "the token field carries the signed token under the envelope name" do
    html = clickwrap_presentation_token_field(@presentation)

    assert_match(/name="clickwrap_submission\[presentation_token\]"/, html)
    assert_includes html, @presentation.token
    refute_match(/id=/, html)
  end

  test "a statement checkbox renders unchecked under the declared name, id, and required rule" do
    statement = @presentation.statement("terms")
    html = clickwrap_statement_check_box(statement, class: "host-style")

    assert_match(/name="clickwrap_submission\[answers\]\[terms\]"/, html)
    assert_match(/id="#{statement.control_id}"/, html)
    assert_match(/required/, html)
    assert_match(/class="host-style"/, html)
    refute_match(/checked/, html)
  end

  test "checked: true exists for re-renders, and required can be overridden" do
    statement = @presentation.statement("terms")

    assert_match(/checked/, clickwrap_statement_check_box(statement, checked: true))
    refute_match(/required/, clickwrap_statement_check_box(statement, required: false))
  end

  test "radio options share the statement's control name with value-suffixed ids" do
    statement = @presentation.statement("terms")
    affirmative = clickwrap_statement_radio_button(statement, "1")
    negative = clickwrap_statement_radio_button(statement, "0")

    [affirmative, negative].each do |html|
      assert_match(/name="clickwrap_submission\[answers\]\[terms\]"/, html)
    end
    assert_match(/id="#{statement.control_id}_1"/, affirmative)
    assert_match(/id="#{statement.control_id}_0"/, negative)
    refute_match(/checked/, affirmative)
  end

  test "the submit button is worded by the manifest, so custom surfaces cannot drift" do
    html = clickwrap_submit_button(@presentation, class: "host-button")

    assert_match(/value="Crear cuenta"/, html)
    assert_match(/class="host-button"/, html)
  end
end
