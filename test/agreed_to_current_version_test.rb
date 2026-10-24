# frozen_string_literal: true

require "test_helper"

# `agreed_to_current_version_of?` is the question a re-acceptance gate asks:
# did this person agree to the Terms in force now, under any policy? The dummy
# app records `agree_to :terms` under two policies, as a real app does: the
# signup form (`:signup`) and the re-acceptance screen (`:current_terms`).
class AgreedToCurrentVersionTest < ActiveSupport::TestCase
  setup do
    @user = create_user
  end

  test "an agreement to the version in force counts" do
    submit_clickwrap(:current_terms, actor: @user, answers: { terms: "1" })

    assert @user.clickwraps.agreed_to_current_version_of?(:terms)
  end

  test "an agreement to an older version only does not count" do
    submit_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
    publish_new_document_version!(:terms, version: "2026-12-01")

    assert_not @user.clickwraps.agreed_to_current_version_of?(:terms)
    assert @user.clickwraps.agreed_to?(:terms), "the agreement still stands; it is to an older version"
  end

  test "a version with a later effective_at counts only from that time" do
    submit_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
    publish_scheduled_terms!(version: "2027-01-01", effective_at: 1.day.from_now)

    assert @user.clickwraps.agreed_to_current_version_of?(:terms),
           "a version not in force yet does not undo the agreement to the version in force"

    travel 2.days do
      assert_not @user.clickwraps.agreed_to_current_version_of?(:terms)
    end
  end

  test "an agreement to the version in force still counts when a later version is scheduled" do
    submit_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })
    publish_new_document_version!(:terms, version: "2026-12-01")
    submit_clickwrap(:current_terms, actor: @user, answers: { terms: "1" })
    publish_scheduled_terms!(version: "2027-01-01", effective_at: 1.day.from_now)

    assert @user.clickwraps.agreed_to_current_version_of?(:terms)

    travel 2.days do
      assert_not @user.clickwraps.agreed_to_current_version_of?(:terms)
    end
  end

  test "the agreement counts under either policy" do
    submit_clickwrap(:signup, actor: @user, answers: { terms: "1", privacy_notice: "1" })

    assert @user.clickwraps.agreed_to_current_version_of?(:terms),
           "the signup agreement to the version in force counts"
    assert_not @user.clickwraps.current_for?(:current_terms),
               "the re-acceptance policy alone would send this person back to accept the same text"

    publish_new_document_version!(:terms, version: "2026-12-01")
    assert_not @user.clickwraps.agreed_to_current_version_of?(:terms)

    submit_clickwrap(:current_terms, actor: @user, answers: { terms: "1" })
    assert @user.clickwraps.agreed_to_current_version_of?(:terms),
           "the re-acceptance counts, although the signup agreement is to the older version"
  end

  test "no agreement at all is false" do
    assert_not @user.clickwraps.agreed_to_current_version_of?(:terms)

    submit_clickwrap(:marketing_preferences, actor: @user, answers: { product_updates: "1" })
    assert_not @user.clickwraps.agreed_to_current_version_of?(:terms)
  end

  test "an agreement that no longer stands, or an exemption, does not count" do
    submit_clickwrap(:current_terms, actor: @user, answers: { terms: "1" })
    Clickwrap.supersede!(:terms, actor: @user, because: "The agreement was replaced by a signed contract")

    assert_not @user.clickwraps.agreed_to_current_version_of?(:terms)

    exempted = create_user
    Clickwrap.exempt!(:seeded_signup, actor: exempted, because: "A demo account that no person signed up for")

    assert_not exempted.clickwraps.agreed_to_current_version_of?(:terms)
  end

  private

  def publish_scheduled_terms!(version:, effective_at:)
    Clickwrap.document(:terms, version: version, locale: :en, effective_at: effective_at,
                               content: "Terms of Service, version #{version}.")
    Clickwrap.publish!
  end
end
