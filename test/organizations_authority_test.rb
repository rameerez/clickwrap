# frozen_string_literal: true

require "test_helper"

# Test-only public-API double for the optional organizations gem. It uses a
# real Active Record represented party so the presentation/event/receipt path
# is exercised end to end, while keeping organizations out of Clickwrap's
# dependency graph.
module Organizations
  module Roles
  end

  class Membership
    attr_reader :id, :user_id, :role

    def initialize(id:, user_id:, role:, permissions: [])
      @id = id
      @user_id = user_id
      @role = role.to_s
      @permissions = permissions.map(&:to_sym)
    end

    def role_sym = role.to_sym

    # These names intentionally mirror the organizations gem's public API.
    # Renaming the double would stop testing the adapter we actually ship.
    # rubocop:disable Naming/PredicatePrefix
    def is_at_least?(minimum_role)
      hierarchy = %i[owner admin member viewer]
      hierarchy.index(role_sym) <= hierarchy.index(minimum_role.to_sym)
    end

    def has_permission_to?(permission) = @permissions.include?(permission.to_sym)
    # rubocop:enable Naming/PredicatePrefix
  end

  class MembershipRelation
    attr_reader :locked

    def initialize(memberships)
      @memberships = memberships
      @locked = false
    end

    def lock
      @locked = true
      self
    end

    def find_by(user_id:)
      @memberships.find { |membership| membership.user_id == user_id }
    end
  end

  class Organization < ApplicationRecord
    self.table_name = "organizations"

    def clickwrap_memberships=(memberships)
      @memberships = memberships
    end

    def memberships
      @memberships ||= MembershipRelation.new([])
    end
  end

  # Host applications sometimes expose a domain-specific subclass while the
  # organizations gem keeps Organizations::Organization as its base class.
  class EnterpriseOrganization < Organization
  end
end

class OrganizationsAuthorityTest < ActiveSupport::TestCase
  def setup
    super
    define_organization_policy
  end

  test "an authorized admin binds their organization while remaining the human actor" do
    actor = create_user
    organization = create_test_organization
    membership = membership_for(actor, role: :admin)
    organization.clickwrap_memberships = relation = Organizations::MembershipRelation.new([membership])

    receipt = capture_for(actor, organization)
    event = receipt.event.reload

    assert relation.locked
    assert_equal actor.to_gid.to_s, event.actor_reference
    assert_equal organization.to_gid.to_s, event.represented_party_reference
    assert_equal "Organizations::Organization", event.represented_party_type
    assert_equal "organizations.membership", event.authority_source
    assert_equal "admin", event.authority_role
    assert event.authority_verified_at
    assert_equal "1", event.authority_details.fetch("adapter_version")
    assert_equal "admin", event.authority_details.fetch("minimum_role")
    presented_authority = event.authority_details.fetch("authority_at_presentation")
    assert_equal "verified", presented_authority.fetch("state")
    assert_equal "organizations.membership", presented_authority.fetch("source")
    assert_equal "admin", presented_authority.fetch("role")
    assert presented_authority.fetch("verified_at").present?
    assert event.digest_verified?

    acting_for = receipt.to_h.dig("actor", "acting_for")
    assert_equal organization.to_gid.to_s, acting_for.fetch("reference")
    assert_equal "admin", acting_for.fetch("authority_role")
  end

  test "authority is verified when the form is presented and reread when it is captured" do
    actor = create_user
    organization = create_test_organization
    admin_membership = membership_for(actor, role: :admin)
    organization.clickwrap_memberships = Organizations::MembershipRelation.new([admin_membership])

    presentation = present_for(actor, organization)
    presented = presentation.manifest.authority_at_presentation

    assert_equal "verified", presented.fetch("state")
    assert_equal "admin", presented.fetch("role")
    assert_equal "organizations.membership", presented.fetch("source")

    owner_membership = membership_for(actor, role: :owner)
    organization.clickwrap_memberships = Organizations::MembershipRelation.new([owner_membership])
    receipt = capture_presentation(actor, organization, presentation)

    assert_equal "owner", receipt.event.authority_role
    assert_equal "admin",
                 receipt.event.authority_details.dig("authority_at_presentation", "role")
  end

  test "an actor without authority cannot receive an organization-bound presentation" do
    actor = create_user
    organization = create_test_organization
    organization.clickwrap_memberships = Organizations::MembershipRelation.new([
                                                                                 membership_for(actor, role: :member)
                                                                               ])

    assert_raises(Clickwrap::AuthorityNotVerified) { present_for(actor, organization) }
  end

  test "owner inherits an admin minimum role" do
    actor = create_user
    organization = create_test_organization
    organization.clickwrap_memberships = Organizations::MembershipRelation.new([
                                                                                 membership_for(actor, role: :owner)
                                                                               ])

    assert capture_for(actor, organization).digest_verified?
  end

  test "a host subclass of Organizations::Organization is accepted as the represented party" do
    actor = create_user
    organization = Organizations::EnterpriseOrganization.create!(name: "Enterprise")
    organization.clickwrap_memberships = Organizations::MembershipRelation.new([
                                                                                 membership_for(actor, role: :admin)
                                                                               ])

    receipt = capture_for(actor, organization)

    # Active Record polymorphic associations intentionally persist the base
    # class so GlobalID/polymorphic lookup keeps working across STI subclasses.
    assert_equal "Organizations::Organization", receipt.event.represented_party_type
    assert receipt.digest_verified?
  end

  test "organizational acceptance never satisfies the actor's personal-capacity requirement" do
    actor = create_user
    organization = create_test_organization
    organization.clickwrap_memberships = Organizations::MembershipRelation.new([
                                                                                 membership_for(actor, role: :admin)
                                                                               ])

    capture_for(actor, organization)

    assert Clickwrap.current?(:organization_terms, actor: actor, tenant: organization,
                                                   acting_for: organization)
    refute Clickwrap.current?(:organization_terms, actor: actor, tenant: organization)
    assert_equal 1, actor.clickwraps.statement_states.count
    assert_equal organization.to_gid.to_s,
                 actor.clickwraps.statement_states.first.represented_party_reference
  end

  test "ordinary members, strangers, and removed admins are denied" do
    actor = create_user
    organization = create_test_organization

    organization.clickwrap_memberships = Organizations::MembershipRelation.new([
                                                                                 membership_for(actor, role: :member)
                                                                               ])
    assert_raises(Clickwrap::AuthorityNotVerified) { present_for(actor, organization) }

    organization.clickwrap_memberships = Organizations::MembershipRelation.new([])
    assert_raises(Clickwrap::AuthorityNotVerified) { present_for(actor, organization) }
  end

  test "authority is checked at submit so a role removed after presentation is denied" do
    actor = create_user
    organization = create_test_organization
    organization.clickwrap_memberships = Organizations::MembershipRelation.new([
                                                                                 membership_for(actor, role: :admin)
                                                                               ])
    presentation = present_for(actor, organization)

    organization.clickwrap_memberships = Organizations::MembershipRelation.new([])

    assert_raises(Clickwrap::AuthorityNotVerified) do
      capture_presentation(actor, organization, presentation)
    end
  end

  test "a represented organization deleted after presentation is denied even if an association object is stale" do
    actor = create_user
    organization = create_test_organization
    organization.clickwrap_memberships = Organizations::MembershipRelation.new([
                                                                                 membership_for(actor, role: :admin)
                                                                               ])
    presentation = present_for(actor, organization)

    organization.destroy!

    assert_raises(Clickwrap::AuthorityNotVerified) do
      capture_presentation(actor, organization, presentation)
    end
  end

  test "a signed presentation cannot be moved to another represented party" do
    actor = create_user
    first = create_test_organization
    second = create_test_organization
    first.clickwrap_memberships = Organizations::MembershipRelation.new([membership_for(actor, role: :admin)])
    second.clickwrap_memberships = Organizations::MembershipRelation.new([membership_for(actor, role: :admin)])
    presentation = present_clickwrap(
      :organization_terms,
      actor: actor,
      acting_for: first
    )

    error = assert_raises(Clickwrap::PresentationInvalid) do
      Clickwrap.capture!(
        :organization_terms,
        actor: actor,
        acting_for: second,
        submission: submission_for(presentation, "terms" => "1")
      )
    end

    assert_equal :represented_party_mismatch, error.result.error
    assert_equal 0, Clickwrap::Event.where(policy_key: "organization_terms").count
  end

  test "an organizations authority presentation cannot cross tenant context" do
    actor = create_user
    organization = create_test_organization
    another_tenant = create_organization
    organization.clickwrap_memberships = Organizations::MembershipRelation.new([
                                                                                 membership_for(actor, role: :admin)
                                                                               ])
    presentation = present_for(actor, organization)

    error = assert_raises(Clickwrap::PresentationInvalid) do
      Clickwrap.capture!(
        :organization_terms,
        actor: actor,
        acting_for: organization,
        tenant: another_tenant,
        submission: submission_for(presentation, "terms" => "1")
      )
    end

    assert_equal :presentation_tenant_mismatch, error.result.error
  end

  test "a policy must explicitly choose organization role or permission authority" do
    error = assert_raises(Clickwrap::DefinitionError) do
      Clickwrap.policy :unsafe_organization_terms do
        agree_to :terms
        permit_acting_for_organization
        retain_with :ordinary_agreement_evidence
      end
    end

    assert_match(/membership alone does not establish legal authority/, error.message)
  end

  test "generic represented-party authority must name the permitted record types" do
    error = assert_raises(Clickwrap::DefinitionError) do
      Clickwrap.policy :unsafe_generic_authority do
        agree_to :terms
        permit_acting_for using: :host
        retain_with :ordinary_agreement_evidence
      end
    end

    assert_match(/at least one represented-party class name/, error.message)
  end

  test "a directly constructed authority rule cannot authorize every record type" do
    error = assert_raises(Clickwrap::DefinitionError) do
      Clickwrap::AuthorityRule.new(represented_party_types: [])
    end

    assert_match(/must name at least one represented-party class/, error.message)
  end

  test "an authority callback cannot return a bare boolean instead of evidence facts" do
    error = assert_raises(Clickwrap::ConfigurationError) do
      Clickwrap::AuthorityDecision.from(true)
    end

    assert_match(/returned bare true/, error.message)
    assert_match(/source.*role.*verified_at/, error.message)
    refute Clickwrap::AuthorityDecision.from(false).authorized?
  end

  test "an authority callback cannot silently misspell an evidence attribute" do
    error = assert_raises(Clickwrap::ConfigurationError) do
      Clickwrap::AuthorityDecision.from(authorized: true, soruce: "membership")
    end

    assert_match(/unknown attribute `soruce:`/, error.message)
  end

  test "a policy can require an organizations permission instead of a role" do
    Clickwrap.policy :organization_export do
      agree_to :terms
      permit_acting_for_organization when_actor_has_permission: :export_data
      retain_with :ordinary_agreement_evidence
    end

    actor = create_user
    organization = create_test_organization
    membership = membership_for(actor, role: :member, permissions: [:export_data])
    organization.clickwrap_memberships = Organizations::MembershipRelation.new([membership])
    presentation = present_clickwrap(
      :organization_export,
      actor: actor,
      tenant: organization,
      acting_for: organization
    )

    receipt = committed_test_receipt(Clickwrap.capture!(
                                       :organization_export,
                                       actor: actor,
                                       tenant: organization,
                                       acting_for: organization,
                                       submission: submission_for(presentation, "terms" => "1")
                                     ))

    assert_equal "export_data", receipt.event.authority_details.fetch("required_permission")
  end

  test "a policy must explicitly opt in before it can create the represented organization" do
    actor = create_user
    organization = Organizations::Organization.new(name: "Prospective")

    error = assert_raises(Clickwrap::DefinitionError) do
      Clickwrap.present(
        :organization_terms,
        actor: actor,
        acting_for: organization,
        represented_party_creation_flow_id: SecureRandom.uuid,
        submit_button_text: "Create organization"
      )
    end

    assert_match(/does not permit creating the represented party/, error.message)
  end

  test "a new organization and its represented-party evidence commit together" do
    define_organization_creation_policy
    actor = create_user
    prospective_organization = Organizations::Organization.new(name: "Prospective")
    flow_id = SecureRandom.uuid
    presentation = present_new_organization_for(actor, prospective_organization, flow_id)

    assert presentation.manifest.represented_party_will_be_created_by_protected_action?
    assert_equal flow_id, presentation.manifest.represented_party_creation_flow_id
    assert_equal "not_yet_verifiable",
                 presentation.manifest.authority_at_presentation.fetch("state")

    organization = nil
    receipt = Clickwrap.create_represented_party!(
      :organization_creation,
      actor: actor,
      represented_party: prospective_organization,
      represented_party_creation_flow_id: flow_id,
      submission: submission_for(presentation, "terms" => "1")
    ) do
      organization = Organizations::Organization.create!(name: "Created by service")
      owner_membership = membership_for(actor, role: :owner)
      organization.clickwrap_memberships = Organizations::MembershipRelation.new([owner_membership])
      organization
    end
    receipt = committed_test_receipt(receipt)
    event = receipt.event.reload

    assert_equal organization.to_gid.to_s, event.represented_party_reference
    assert_equal "owner", event.authority_role
    assert_equal "organizations.membership", event.authority_source
    assert_equal true,
                 event.authority_details.fetch("represented_party_was_created_by_protected_action")
    assert_equal "not_yet_verifiable",
                 event.authority_details.dig("authority_at_presentation", "state")
    assert event.digest_verified?
  end

  test "a new organization rolls back when post-creation authority cannot be verified" do
    define_organization_creation_policy
    actor = create_user
    organization = Organizations::Organization.new(name: "No owner")
    flow_id = SecureRandom.uuid
    presentation = present_new_organization_for(actor, organization, flow_id)

    assert_raises(Clickwrap::AuthorityNotVerified) do
      Clickwrap.create_represented_party!(
        :organization_creation,
        actor: actor,
        represented_party: organization,
        represented_party_creation_flow_id: flow_id,
        submission: submission_for(presentation, "terms" => "1")
      ) do
        organization.save!
        organization.clickwrap_memberships = Organizations::MembershipRelation.new([])
        organization
      end
    end

    assert_not Organizations::Organization.exists?(name: "No owner")
    assert_no_clickwrap_event :organization_creation
  end

  test "a failed evidence write never creates the represented organization" do
    define_organization_creation_policy
    actor = create_user
    organization = Organizations::Organization.new(name: "Atomic")
    flow_id = SecureRandom.uuid
    presentation = present_new_organization_for(actor, organization, flow_id)

    Clickwrap::Testing.fail_next_event_write do
      assert_raises(Clickwrap::EventWriteFailed) do
        Clickwrap.create_represented_party!(
          :organization_creation,
          actor: actor,
          represented_party: organization,
          represented_party_creation_flow_id: flow_id,
          submission: submission_for(presentation, "terms" => "1")
        ) do
          organization.save!
          owner_membership = membership_for(actor, role: :owner)
          organization.clickwrap_memberships = Organizations::MembershipRelation.new([owner_membership])
          organization
        end
      end
    end

    assert_not Organizations::Organization.exists?(name: "Atomic")
  end

  test "the represented-party creation block must return a persisted record of the presented type" do
    define_organization_creation_policy
    actor = create_user
    organization = Organizations::Organization.new(name: "Unpersisted")
    flow_id = SecureRandom.uuid
    presentation = present_new_organization_for(actor, organization, flow_id)

    unpersisted_result = Organizations::Organization.new(name: "Different")
    error = assert_raises(Clickwrap::RepresentedPartyCreationFailed) do
      Clickwrap.create_represented_party!(
        :organization_creation,
        actor: actor,
        represented_party: organization,
        represented_party_creation_flow_id: flow_id,
        submission: submission_for(presentation, "terms" => "1")
      ) { unpersisted_result }
    end

    assert_match(/must return the persisted represented party/, error.message)
    assert_not Organizations::Organization.exists?(name: "Different")
    assert_no_clickwrap_event :organization_creation
  end

  test "the represented-party creation block cannot return a persisted record of another type" do
    define_organization_creation_policy
    actor = create_user
    organization = Organizations::Organization.new(name: "Prospective")
    flow_id = SecureRandom.uuid
    presentation = present_new_organization_for(actor, organization, flow_id)

    error = assert_raises(Clickwrap::RepresentedPartyCreationFailed) do
      Clickwrap.create_represented_party!(
        :organization_creation,
        actor: actor,
        represented_party: organization,
        represented_party_creation_flow_id: flow_id,
        submission: submission_for(presentation, "terms" => "1")
      ) { create_user }
    end

    assert_match(/returned User.*bound to Organizations::Organization/, error.message)
    assert_no_clickwrap_event :organization_creation
  end

  test "a represented-party creation presentation cannot cross browser flows" do
    define_organization_creation_policy
    actor = create_user
    organization = Organizations::Organization.new(name: "Prospective")
    flow_id = SecureRandom.uuid
    presentation = present_new_organization_for(actor, organization, flow_id)

    error = assert_raises(Clickwrap::PresentationInvalid) do
      Clickwrap.create_represented_party!(
        :organization_creation,
        actor: actor,
        represented_party: organization,
        represented_party_creation_flow_id: SecureRandom.uuid,
        submission: submission_for(presentation, "terms" => "1")
      ) { organization.save! }
    end

    assert_equal :represented_party_creation_flow_mismatch, error.result.error
    assert_not organization.persisted?
  end

  test "an identical represented-party creation retry returns the original receipt without creating twice" do
    define_organization_creation_policy
    actor = create_user
    organization = Organizations::Organization.new(name: "Once")
    flow_id = SecureRandom.uuid
    presentation = present_new_organization_for(actor, organization, flow_id)
    submission = submission_for(presentation, "terms" => "1")
    runs = 0

    first = Clickwrap.create_represented_party!(
      :organization_creation,
      actor: actor,
      represented_party: organization,
      represented_party_creation_flow_id: flow_id,
      submission: submission
    ) do
      runs += 1
      organization.save!
      owner_membership = membership_for(actor, role: :owner)
      organization.clickwrap_memberships = Organizations::MembershipRelation.new([owner_membership])
      organization
    end
    first = committed_test_receipt(first)

    retry_record = Organizations::Organization.new(name: "Ignored retry input")
    second = Clickwrap.create_represented_party!(
      :organization_creation,
      actor: actor,
      represented_party: retry_record,
      represented_party_creation_flow_id: flow_id,
      submission: submission
    ) do
      runs += 1
      retry_record.save!
    end

    assert_equal first.event_id, second.event_id
    assert_equal 1, runs
    assert_equal 1, Organizations::Organization.where(name: "Once").count
    assert_not Organizations::Organization.exists?(name: "Ignored retry input")
  end

  test "a remediation route preserves the exact organization and tenant selected by the server" do
    actor = create_user
    organization = create_test_organization
    organization.clickwrap_memberships = Organizations::MembershipRelation.new([
                                                                                 membership_for(actor, role: :admin)
                                                                               ])
    policy = Clickwrap.policy!(:organization_terms)
    token = Clickwrap::RemediationToken.issue(
      policy: policy,
      actor: actor,
      tenant: organization,
      represented_party: organization,
      return_to: "/organization/settings"
    )

    context = Clickwrap::RemediationToken.resolve!(
      token,
      policy: policy,
      actor: actor,
      tenant: organization
    )

    assert_equal organization, context.represented_party
    assert_equal organization.to_gid.to_s, context.tenant_reference
    assert_equal "/organization/settings", context.return_to
  end

  test "a remediation route cannot be moved to another actor or tenant" do
    actor = create_user
    another_actor = create_user
    organization = create_test_organization
    another_organization = create_test_organization
    policy = Clickwrap.policy!(:organization_terms)
    token = Clickwrap::RemediationToken.issue(
      policy: policy,
      actor: actor,
      tenant: organization,
      represented_party: organization
    )

    actor_error = assert_raises(Clickwrap::RemediationInvalid) do
      Clickwrap::RemediationToken.resolve!(
        token,
        policy: policy,
        actor: another_actor,
        tenant: organization
      )
    end
    assert_match(/different actor/, actor_error.message)

    tenant_error = assert_raises(Clickwrap::RemediationInvalid) do
      Clickwrap::RemediationToken.resolve!(
        token,
        policy: policy,
        actor: actor,
        tenant: another_organization
      )
    end
    assert_match(/different tenant/, tenant_error.message)
  end

  test "a represented organization that disappears cannot be recovered from an old remediation route" do
    actor = create_user
    organization = create_test_organization
    policy = Clickwrap.policy!(:organization_terms)
    token = Clickwrap::RemediationToken.issue(
      policy: policy,
      actor: actor,
      tenant: organization,
      represented_party: organization
    )

    organization.destroy!

    error = assert_raises(Clickwrap::RemediationInvalid) do
      Clickwrap::RemediationToken.resolve!(
        token,
        policy: policy,
        actor: actor,
        tenant: organization
      )
    end
    assert_match(/represented party no longer exists/, error.message)
  end

  test "tampered and expired organization remediation routes are refused" do
    actor = create_user
    organization = create_test_organization
    policy = Clickwrap.policy!(:organization_terms)
    token = Clickwrap::RemediationToken.issue(
      policy: policy,
      actor: actor,
      tenant: organization,
      represented_party: organization
    )
    tampered = token.dup
    tampered.setbyte(tampered.bytesize / 2, tampered.getbyte(tampered.bytesize / 2) ^ 1)

    assert_raises(Clickwrap::RemediationInvalid) do
      Clickwrap::RemediationToken.resolve!(
        tampered,
        policy: policy,
        actor: actor,
        tenant: organization
      )
    end

    expired = Clickwrap::RemediationToken.issue(
      policy: policy,
      actor: actor,
      tenant: organization,
      represented_party: organization,
      issued_at: 1.day.ago
    )
    assert_raises(Clickwrap::RemediationInvalid) do
      Clickwrap::RemediationToken.resolve!(
        expired,
        policy: policy,
        actor: actor,
        tenant: organization
      )
    end
  end

  private

  def define_organization_policy
    Clickwrap.policy :organization_terms do
      agree_to :terms
      permit_acting_for_organization when_actor_is_at_least: :admin
      retain_with :ordinary_agreement_evidence
    end
  end

  def define_organization_creation_policy
    Clickwrap.policy :organization_creation do
      agree_to :terms
      permit_acting_for_organization(
        when_actor_is_at_least: :owner,
        including_when_this_action_creates_the_organization: true
      )
      retain_with :ordinary_agreement_evidence
    end
  end

  def create_test_organization
    Organizations::Organization.create!(name: "Represented #{SecureRandom.hex(3)}")
  end

  def membership_for(actor, role:, permissions: [])
    Organizations::Membership.new(
      id: SecureRandom.random_number(100_000),
      user_id: actor.id,
      role: role,
      permissions: permissions
    )
  end

  def present_for(actor, organization)
    present_clickwrap(
      :organization_terms,
      actor: actor,
      tenant: organization,
      acting_for: organization
    )
  end

  def present_new_organization_for(actor, organization, flow_id)
    Clickwrap.present(
      :organization_creation,
      actor: actor,
      acting_for: organization,
      represented_party_creation_flow_id: flow_id,
      submit_button_text: "Create organization"
    )
  end

  def capture_for(actor, organization)
    capture_presentation(actor, organization, present_for(actor, organization))
  end

  def capture_presentation(actor, organization, presentation)
    committed_test_receipt(Clickwrap.capture!(
                             :organization_terms,
                             actor: actor,
                             tenant: organization,
                             acting_for: organization,
                             submission: submission_for(presentation, "terms" => "1")
                           ))
  end
end
