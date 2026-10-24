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

  test "the predicate and verification switch together at effective_at" do
    submit_clickwrap(:current_terms, actor: @user, answers: { terms: "1" })
    effective_at = 1.day.from_now.change(usec: 0)
    publish_scheduled_terms!(version: "2027-01-01", effective_at: effective_at)

    travel_to(effective_at - 0.000001, with_usec: true) do
      assert @user.clickwraps.agreed_to_current_version_of?(:terms), "the instant before, the old version is in force"
      assert Clickwrap.verify(:current_terms, actor: @user).success?
    end

    travel_to(effective_at, with_usec: true) do
      assert_not @user.clickwraps.agreed_to_current_version_of?(:terms), "at effective_at, the new version is in force"
      assert_equal :unseen_document_version, Clickwrap.verify(:current_terms, actor: @user).error
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

  # --- Documents --------------------------------------------------------------

  test "a statement that binds two documents counts only while both are in force" do
    define_service_agreement(documents: %i[terms privacy_notice])
    submit_clickwrap(:service_agreement, actor: @user, answers: { service_terms: "1" })

    assert @user.clickwraps.agreed_to_current_version_of?(:service_terms)
    assert Clickwrap.verify(:service_agreement, actor: @user).success?

    publish_new_document_version!(:privacy_notice, version: "2026-12-01")

    assert_not @user.clickwraps.agreed_to_current_version_of?(:service_terms),
               "a change to the second document only is enough"
    result = Clickwrap.verify(:service_agreement, actor: @user)
    assert_equal :unseen_document_version, result.error
    assert_equal "privacy_notice", result.details["document"]
  end

  test "a published document added to the statement after the agreement makes it not current" do
    define_service_agreement(documents: %i[terms])
    submit_clickwrap(:service_agreement, actor: @user, answers: { service_terms: "1" })
    assert @user.clickwraps.agreed_to_current_version_of?(:service_terms)

    # The next deploy binds the Privacy Notice too. It was already published,
    # but this agreement never recorded a version of it.
    reload_declarations
    define_service_agreement(documents: %i[terms privacy_notice])

    assert_not @user.clickwraps.agreed_to_current_version_of?(:service_terms)
    result = Clickwrap.verify(:service_agreement, actor: @user)
    assert_equal :unseen_document_version, result.error
    assert_equal "privacy_notice", result.details["document"]
  end

  # --- Scope --------------------------------------------------------------------

  test "the default scope is the scope of agreed_to?, where tenant_is :not_applicable records" do
    submit_clickwrap(:current_terms, actor: @user, answers: { terms: "1" })
    organization = create_organization

    assert_equal "", @user.clickwraps.statement_states.sole.tenant_key
    assert @user.clickwraps.agreed_to_current_version_of?(:terms)
    assert @user.clickwraps.agreed_to?(:terms)
    assert_not @user.clickwraps.agreed_to_current_version_of?(:terms, tenant: organization)
    assert_not @user.clickwraps.agreed_to?(:terms, tenant: organization)
  end

  test "an agreement in a tenant counts in that tenant only" do
    organization = create_organization
    submit_clickwrap(:signup, actor: @user, tenant: organization, answers: { terms: "1", privacy_notice: "1" })

    assert @user.clickwraps.agreed_to_current_version_of?(:terms, tenant: organization)
    assert @user.clickwraps.agreed_to?(:terms, tenant: organization)
    assert_not @user.clickwraps.agreed_to_current_version_of?(:terms)
    assert_not @user.clickwraps.agreed_to?(:terms)
    assert_not @user.clickwraps.agreed_to_current_version_of?(:terms, tenant: create_organization)

    publish_new_document_version!(:terms, version: "2026-12-01")

    assert_not @user.clickwraps.agreed_to_current_version_of?(:terms, tenant: organization),
               "the tenant was offered the shared Terms, so a new shared version is in force for it"
  end

  test "a tenant's own document is the one compared, not the shared one" do
    organization = create_organization
    tenant_key = Clickwrap::Reference.tenant(organization)
    publish_tenant_terms!(tenant_key, version: "2026-08-15")
    submit_clickwrap(:signup, actor: @user, tenant: organization, answers: { terms: "1", privacy_notice: "1" })

    publish_new_document_version!(:terms, version: "2026-12-01")
    assert @user.clickwraps.agreed_to_current_version_of?(:terms, tenant: organization),
           "a new shared version does not replace the tenant's own Terms"

    publish_tenant_terms!(tenant_key, version: "2026-12-01")
    assert_not @user.clickwraps.agreed_to_current_version_of?(:terms, tenant: organization)
  end

  test "require_current_version re-asks tenant evidence when the shared document moves on" do
    Clickwrap.policy :organization_reacceptance do
      tenant_is :required
      agree_to :terms, require_current_version: true
    end
    organization = create_organization
    submit_clickwrap(:organization_reacceptance, actor: @user, tenant: organization, answers: { terms: "1" })
    assert Clickwrap.verify(:organization_reacceptance, actor: @user, tenant: organization).success?

    publish_new_document_version!(:terms, version: "2026-12-01")

    assert_equal :unseen_document_version,
                 Clickwrap.verify(:organization_reacceptance, actor: @user, tenant: organization).error
  end

  test "an agreement about a subject counts for that subject only" do
    Clickwrap.policy :engagement_terms do
      agree_to :terms
    end
    engagement = create_withdrawal(user: @user)
    submit_clickwrap(:engagement_terms, actor: @user, subject: engagement, answers: { terms: "1" })

    assert @user.clickwraps.agreed_to_current_version_of?(:terms, subject: engagement)
    assert @user.clickwraps.agreed_to?(:terms, subject: engagement)
    assert_not @user.clickwraps.agreed_to_current_version_of?(:terms)
    assert_not @user.clickwraps.agreed_to?(:terms)
    assert_not @user.clickwraps.agreed_to_current_version_of?(:terms, subject: create_withdrawal(user: @user))
  end

  # --- Cost -----------------------------------------------------------------------

  test "each document is looked up once per call, by id, however many policies recorded it" do
    %i[reseller_terms partner_terms].each do |key|
      Clickwrap.policy(key) do
        tenant_is :not_applicable
        agree_to :terms
      end
    end

    single = create_user
    submit_clickwrap(:signup, actor: single, answers: { terms: "1", privacy_notice: "1" })

    several = create_user
    %i[signup seeded_signup].each do |key|
      submit_clickwrap(key, actor: several, answers: { terms: "1", privacy_notice: "1" })
    end
    %i[current_terms reseller_terms partner_terms].each do |key|
      submit_clickwrap(key, actor: several, answers: { terms: "1" })
    end
    publish_new_document_version!(:terms, version: "2026-12-01")

    one = count_queries { assert_not single.clickwraps.agreed_to_current_version_of?(:terms) }
    statements = sql_statements { assert_not several.clickwraps.agreed_to_current_version_of?(:terms) }

    assert_equal 5, several.clickwraps.statement_states.where(statement_key: "terms").count
    assert_equal one, statements.size, "five stale policies cost what one costs"
    assert_equal 3, statements.size, "the agreements, the document, its version in force"

    version_queries = statements.grep(/clickwrap_document_versions/)
    assert_equal 1, version_queries.size
    version_queries.each { |sql| assert_no_match(/\*/, sql, "the lookup reads the version id, never its bytes") }
  end

  private

  def publish_scheduled_terms!(version:, effective_at:)
    Clickwrap.document(:terms, version: version, locale: :en, effective_at: effective_at,
                               content: "Terms of Service, version #{version}.")
    Clickwrap.publish!
  end

  def publish_tenant_terms!(tenant_key, version:)
    Clickwrap.document(:terms, tenant: tenant_key, version: version, locale: :en,
                               content: "Terms of Service for one organization, version #{version}.")
    Clickwrap.publish!
  end

  def define_service_agreement(documents:)
    Clickwrap.policy :service_agreement do
      tenant_is :not_applicable
      agree_to :service_terms, document: documents,
                               statement: "I agree to the service documents.",
                               require_current_version: true
    end
  end

  # What a deploy does: the declarations are read again from the files.
  def reload_declarations
    Clickwrap::Services::LoadPolicies.new(root: Rails.root.to_s, paths: ["config/clickwrap.rb"]).call
  end

  def sql_statements
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql] unless %w[SCHEMA TRANSACTION].include?(payload[:name])
    end

    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
