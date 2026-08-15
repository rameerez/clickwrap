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

## What is checked at submit

The built-in adapter has no hard runtime dependency on `organizations`; it is
used only by a policy that calls `permit_acting_for_organization`. At capture it:

1. requires a persisted `Organizations::Organization` (host subclasses are
   accepted);
2. requires the actor to have a current membership in that exact organization;
3. locks and rereads the membership inside the capture transaction;
4. checks the configured minimum role and/or permission; and
5. records the membership reference, actual role, configured criterion,
   adapter version, verification time, and available authentication method.

That means an admin removed or demoted after the page was rendered is denied at
submit. A token rendered for one organization cannot be submitted for another,
and an organizational acceptance never satisfies a personal-capacity query:

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

## The legal boundary

The `organizations` role or permission is an application authorization fact.
Clickwrap records that fact and its provenance; it cannot decide whether an
`admin`, officer, employee, guardian, or agent has legal capacity to bind a
party for a particular agreement in a particular jurisdiction. Choose the
criterion with counsel, use interface copy that makes the represented capacity
conspicuous, and keep any organization identity fields your evidentiary policy
requires. The built-in adapter records stable database/GlobalID references; it
does not claim that an organization display name is a verified legal name or
that a membership role is statutory authority.

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
