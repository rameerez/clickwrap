# Binding an organization through a human actor

Clickwrap keeps the person who acted and the party they represented as two
different facts:

| Concept | Typical `organizations` record | What it means |
|---|---|---|
| actor | `current_user` | The human account that performed the clickwrap action |
| represented party (`acting_for`) | `current_organization` | The organization the action is intended to bind |
| tenant | usually `current_organization` | The application data boundary in which the action happened |
| subject | optional domain record | The exact order, withdrawal, contract, or other object the statement covers |

A `User` therefore does not disappear behind an organization. The event and
receipt keep both references, plus the membership evidence used to authorize
the represented action.

## One policy line

Choose the organization role your application and counsel have reviewed:

```ruby
Clickwrap.policy :organization_terms do
  agree_to :organization_terms

  permit_acting_for_organization when_actor_is_at_least: :admin

  retain_with :ordinary_agreement_evidence
end
```

Or name a purpose-specific permission from the `organizations` gem instead of
coupling the decision to a broad role:

```ruby
Clickwrap.policy :data_processing_terms do
  agree_to :data_processing_terms

  permit_acting_for_organization \
    when_actor_has_permission: :accept_data_processing_terms

  retain_with :ordinary_agreement_evidence
end
```

If both options are present, both must pass. A policy with neither is rejected
at boot: organization membership by itself is not treated as legal authority.

The permission-oriented form is usually the more durable design. It lets an
application grant exactly “may accept these terms for this organization”
without silently equating that power with every other thing an `admin` can do.

## Present and capture the same represented party

Make organizational capacity visible in both the interface copy and the Ruby
call:

```erb
<%= form_with model: @agreement do |form| %>
  <p>
    You are accepting these terms for
    <strong><%= current_organization.name %></strong>.
  </p>

  <%= form.clickwrap :organization_terms,
        acting_for: current_organization,
        submit: "Accept for #{current_organization.name}" %>
<% end %>
```

Then pass the server-owned organization again at submit:

```ruby
def create
  organization = current_organization

  capture_clickwrap_and!(
    :organization_terms,
    acting_for: organization
  ) do |pending_receipt|
    organization.update!(
      terms_accepted_with_clickwrap_event_id: pending_receipt.event_id
    )
  end

  redirect_to organization_settings_path
end
```

Do not permit an organization ID from the form and turn it into
`acting_for:`. Resolve the organization from the authenticated server-side
context. The signed presentation is also bound to that exact represented-party
reference, so it cannot be moved to another organization between render and
submit.

If the application uses the organization as its Clickwrap tenant too, configure
that once:

```ruby
Clickwrap.configure do |config|
  config.find_current_tenant_with = ->(controller) {
    controller.current_organization
  }
end
```

The controller helper then supplies the tenant automatically. `acting_for:`
stays explicit because “this happened inside Acme” and “this person intended to
bind Acme” are not interchangeable claims.

## What is checked at presentation and submit

The built-in adapter has no hard runtime dependency on `organizations`; it is
used only by a policy that calls `permit_acting_for_organization`. For a
persisted organization it:

1. requires a persisted `Organizations::Organization` (host subclasses are
   accepted);
2. requires the actor to have a current membership in that exact organization
   before rendering the form;
3. signs the presentation-time membership reference, role, source, criterion,
   and verification time into the manifest;
4. locks and rereads the membership inside the capture transaction;
5. checks the configured minimum role and/or permission at both moments; and
6. records both snapshots plus the available authentication method.

That means an admin removed or demoted after the page was rendered is denied at
submit. A role change that remains authorized is not flattened: the receipt
keeps the role at presentation and the role at capture. A token rendered for
one organization cannot be submitted for another, and an organizational
acceptance never satisfies a personal-capacity query:

```ruby
user.clickwraps.current_for?(
  :organization_terms,
  tenant: organization,
  acting_for: organization
) # => true

user.clickwraps.current_for?(
  :organization_terms,
  tenant: organization
) # => false
```

## Create the organization and its evidence together

A person may reach the form before the organization has a row or a membership.
That is not the ordinary `acting_for:` case: Clickwrap cannot truthfully say it
verified a membership that does not exist. Opt into the prospective flow in the
policy, and include an explicit declaration for the real-world authority or
content-rights claim the application needs:

```ruby
Clickwrap.policy :organization_creation do
  declare :authority_and_content_rights,
    statement: "I am authorized to create and act for this organization and may use the content I submit.",
    document: nil,
    protected_outcome_version: "created-organization-v1",
    record_protected_outcome_with: ->(organization) {
      Clickwrap.protected_outcome(
        action: :created,
        record: organization,
        facts: {
          name: organization.name,
          logo_checksum: organization.logo.blob.checksum
        }
      )
    }

  permit_acting_for_organization(
    when_actor_is_at_least: :owner,
    including_when_this_action_creates_the_organization: true
  )

  retain_with :ordinary_agreement_evidence
end
```

Pass the same new model as `acting_for:`. The form helper creates and signs a
server-owned browser-flow identifier; there is no organization id, role, policy
option, or evidence field for the browser to choose:

```erb
<%= form_with model: @organization do |form| %>
  <%# name, logo, and other organization fields %>

  <%= form.clickwrap :organization_creation,
        acting_for: @organization,
        submit: "Create organization" %>
<% end %>
```

At submit, return the persisted organization after creating its owner
membership in the protected block. The result may come from an ordinary
creation service; it must have the same class the presentation bound:

```ruby
def create
  @organization = Organizations::Organization.new(organization_params)

  receipt = create_represented_party_with_clickwrap(
    :organization_creation,
    represented_party: @organization
  ) do |pending_receipt|
    @organization.save!
    @organization.add_member!(current_user, role: :owner)
    @organization.update!(creation_clickwrap_event_id: pending_receipt.event_id)
    @organization
  end

  redirect_to organization_path(receipt.event.represented_party)
end
```

The manifest labels presentation-time authority `not_yet_verifiable`. After the
block returns the persisted record, the configured adapter verifies the new
owner membership inside the same transaction, and the event is rebound to the final
stable organization reference before its digest and projections are written.
An evidence-write failure, model-validation failure, missing/insufficient
membership, protected-outcome failure, or outer transaction rollback leaves no
created organization or Clickwrap event. An identical nonce retry returns the
original receipt without running the creation block twice.

That post-creation owner check proves only the application state the block just
created. It does not prove that the person already had real-world authorization
to use a legal name or logo or to bind an external company. Record that claim as
an explicit `declare` statement, choose its wording with counsel, and keep the
protected outcome specific enough to identify the organization and submitted
assets it covered.

API clients use the same primitive with a server-owned flow id:

```ruby
Clickwrap.create_represented_party!(
  :organization_creation,
  actor: current_user,
  represented_party: organization,
  represented_party_creation_flow_id: server_session_flow_id,
  http_request: request,
  submission: Clickwrap.submission_from(params)
) do |pending_receipt|
  organization.save!
  organization.add_member!(current_user, role: :owner)
  organization.update!(creation_clickwrap_event_id: pending_receipt.event_id)
  organization
end
```

Pass that same `represented_party_creation_flow_id:` to `Clickwrap.present`.
Do not derive it from form fields or accept it as the authority decision; it is
opaque server session state used only to bind one prospective browser flow.

## The legal boundary

The `organizations` role or permission is an application authorization fact.
Clickwrap records that fact and its provenance; it cannot decide whether an
`admin`, officer, employee, guardian, or agent has legal capacity to bind a
party for a particular agreement in a particular jurisdiction. Spain's Civil
Code Article 1259, for example, makes authorization or legal representation a
substantive issue and addresses later ratification; it does not say that a SaaS
role named `admin` or `owner` supplies that authorization ([official current
consolidated text](https://www.boe.es/eli/es/rd/1889/07/24/%281%29/con),
[official BOE document view with Article 1259](https://www.boe.es/buscar/doc.php?id=BOE-A-1889-4763&lang=es)).
EU eIDAS Article 25 also distinguishes the evidential treatment of an
electronic signature from the specific handwritten-signature equivalence of a
qualified electronic signature ([official consolidated EUR-Lex
text](https://eur-lex.europa.eu/eli/reg/2014/910/en/cons)).

Those are jurisdiction-specific legal sources, not a universal answer. Choose
the criterion and statement with counsel, use interface copy that makes the
represented capacity conspicuous, and keep any organization identity fields
your evidentiary policy requires. The built-in adapter records stable
database/GlobalID references; it does not claim that an organization display
name is a verified legal name, that a membership role is statutory authority,
or that an ordinary click is a qualified electronic signature.

For a different authority system, keep the same actor/represented-party model
and register a named server-side adapter with
`config.register_represented_party_authority`.

## Exact implementation sources

These are source-code observations, not legal authorities:

- The `organizations` gem's public organization and membership APIs are
  documented at
  https://github.com/rameerez/organizations/blob/fd0eace263c54cd3c8ab98a9505190df6856c6d6/README.md#the-complete-api
- Its organization-to-membership association is implemented at
  https://github.com/rameerez/organizations/blob/fd0eace263c54cd3c8ab98a9505190df6856c6d6/lib/organizations/models/organization.rb#L37-L41
- Its membership role and permission checks are implemented at
  https://github.com/rameerez/organizations/blob/fd0eace263c54cd3c8ab98a9505190df6856c6d6/lib/organizations/models/membership.rb#L106-L160
- Its default role hierarchy and permission evaluation are implemented at
  https://github.com/rameerez/organizations/blob/fd0eace263c54cd3c8ab98a9505190df6856c6d6/lib/organizations/roles.rb#L12-L146
