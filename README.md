# ☑️ `clickwrap` - Make your Rails users accept your Terms and legal documents

[![Gem Version](https://badge.fury.io/rb/clickwrap.svg)](https://badge.fury.io/rb/clickwrap) [![Build Status](https://github.com/rameerez/clickwrap/workflows/Tests/badge.svg)](https://github.com/rameerez/clickwrap/actions)

> [!TIP]
> **🚀 Ship your next Rails app 10x faster!** I've built **[RailsFast](https://railsfast.com/?ref=clickwrap)**, a production-ready Rails boilerplate template that comes with everything you need to launch a software business in days, not weeks — including versioned Terms and Privacy Notice acceptance powered by this gem. Go [check it out](https://railsfast.com/?ref=clickwrap)!

`clickwrap` makes your Rails users accept your Terms of Service, acknowledge your Privacy Notice, give (and withdraw) consent, make declarations, and authorize one-time actions — and keeps evidence of all of it that you can still reproduce and verify years later.

✨ Perfect for SaaS signups, marketplaces, fintech payouts, health apps, and any Rails app where "the user agreed to this" needs to be provable long after the fact.

Ordinary Terms acceptance is one line in your signup form:

```erb
<%= form.clickwrap :signup, submit: "Create account" %>
```

And when an action is consequential enough that it must never happen without its evidence (a payout, a data handoff, a contract), the evidence and the action commit in the same database transaction:

```ruby
Clickwrap.capture_and!(:withdrawal_authorization, actor: current_user, subject: withdrawal,
  http_request: request, submission: clickwrap_submission) do |pending_receipt|
  withdrawal.submit!(authorized_by_clickwrap_event: pending_receipt.event_id)
end
```

If the evidence can't be recorded, the action doesn't happen. If the action fails, the evidence doesn't pretend it succeeded.

No JavaScript package. No Redis. No background jobs. No external accounts or per-event API calls. No legal-document vendor. Just Rails, your database, and a DSL that reads like plain English.

> [!IMPORTANT]
> **Status: built and tested, not yet proven in production.** Everything in this README is implemented and covered by the test suite, but the gem hasn't been through its planned production integrations, an unfamiliar-developer usability test, or legal review of its default wording yet. Treat it as a release candidate for evaluation — don't put it under a payout flow just yet. The [stability promise](#stability-and-upgrade-promise) applies from 0.1.0 onward.

## 👨‍💻 Example

Define your documents and a policy in plain Ruby:

```ruby
# config/clickwrap.rb
Clickwrap.document :terms,
  version: "2026-08-15",
  from: Rails.root.join("app/content/legal/terms.md")

Clickwrap.document :privacy_notice,
  version: "2026-08-15",
  from: Rails.root.join("app/content/legal/privacy.md")

Clickwrap.retention :ordinary_agreement_evidence do
  retain_core_event_for 6.years
end

Clickwrap.policy :signup do
  agree_to :terms
  acknowledge :privacy_notice

  retain_with :ordinary_agreement_evidence
end
```

(Yes, the payload-retention decision is mandatory — `clickwrap` will not silently
default captured evidence or request evidence to "keep forever" and will not pick
a period for you. A minimal, digest-linked disposition tombstone remains after a
reviewed core deletion so the deletion itself does not become an unexplained hole.)

Add one macro to your model:

```ruby
class User < ApplicationRecord
  has_clickwraps
end
```

Render the checkboxes and the submit button as one bound presentation:

```erb
<%= form.clickwrap :signup, submit: "Create account" %>
```

From that moment on, you can ask readable questions everywhere:

```ruby
user.clickwraps.agreed_to?(:terms)              # => true
user.clickwraps.acknowledged?(:privacy_notice)  # => true
user.clickwraps.current_for?(:signup)           # => true
```

And every acceptance produces a receipt you can export and verify — even outside your app, without your app's source code:

```ruby
receipt = user.clickwraps.receipts.last
receipt.verify.success?    # => true
receipt.to_canonical_json  # canonical JSON for the standalone verifier
receipt.to_html            # human-readable version of the same evidence
```

Sounds good? Let's get started!

## Quick start

Add the gem and run the installer:

```bash
bundle add clickwrap
bin/rails generate clickwrap:install
bin/rails db:migrate
```

The installer detects Rails authentication vs. Devise, integer vs. UUID primary keys, and your database adapter, then generates adaptive migrations, one annotated initializer, and a conventional signup policy. It never invents legal text and never silently guesses your actor model.

Point the generated policy at the documents your app already owns (see the example above), add `has_clickwraps` to your user model, drop `form.clickwrap` into your signup form, then publish immutable snapshots of your documents:

```bash
bin/rails clickwrap:publish
```

That's it! Your app now records which exact document versions the server offered, which explicit
answers it accepted, the bound presentation wording, and when—atomically with account creation.
Let's see how it works.

Wiring the gem into an existing production app — or handing the job to an AI agent? The
[integrating guide](guides/integrating.md) is the step-by-step playbook from a full
production migration, in the exact order that avoids every mistake we made.

Hotwire Native or another client needs special document-link attributes? Keep
the gem's canonical partial and set `config.document_link_html_options_with`.
It can add `data: { turbo: false }`, `target`, or `rel`; it cannot replace the
immutable `href` that Clickwrap signs into the presentation.

## How it works

Most apps eventually accumulate an `accepted_terms_at` column, a `terms_version` string, a few hidden form fields, an `after_create` callback, and some IP columns. Each part looks reasonable alone. Together they produce partial writes, client-owned policy decisions, mutable history, and evidence only the original engineer can explain.

`clickwrap` replaces that plumbing with one coherent primitive:

1. **Documents are immutable.** Publishing reads the exact bytes, digests them, and freezes a snapshot. A changed document requires a new version — the task refuses to reuse a version label for different bytes.
2. **Policies are server-owned.** The browser may answer; it may never choose the policy, document version, validity, subject, or what gets recorded. Policies compile at boot and fail loudly when misconfigured.
3. **Presentations are signed.** `form.clickwrap` creates a short-lived signed manifest of what the server generated for the form: documents, digests, statements, choices, and the submit button text. Stale, swapped, expired, or cross-account tokens are rejected at submit. A deploy between render and submit cannot record a version that was not bound to the accepted submission. This does not prove human perception or comprehension.
4. **Capture is atomic.** Evidence and the protected database action commit together or not at all. Replays of the same submission return the original result instead of running twice.
5. **Lifecycle history appends.** Through Clickwrap's public/model APIs, withdrawal, expiry, correction, and supersession append new events instead of rewriting the earlier event. Optional PostgreSQL hardening rejects additional direct database mutation paths; the integrity verifier detects covered changes rather than pretending a fully privileged database actor is impossible.
6. **Receipts have a standalone verifier.** Canonical JSON ([RFC 8785](https://www.rfc-editor.org/rfc/rfc8785)) with versioned schemas and SHA-256 digests can be checked by the bundled `clickwrap` CLI without booting Rails. The result distinguishes fully verified, failed, and incomplete checks; document-byte checks need the exported artifacts, and reviewed disposition is reported as disposition rather than ordinary verification.

## Six verbs, six honest meanings

Not every checkbox is "consent," and not every timestamp is a "signature." Each verb gets the lifecycle it actually needs:

| Policy verb | Meaning | Typical lifecycle |
|---|---|---|
| `agree_to` | Assent to contractual terms | agreed → superseded by new version |
| `acknowledge` | Affirmative receipt of a notice or risk | acknowledged → superseded / expired |
| `consent_to` | Purpose-specific permission | granted → withdrawn / renewed |
| `declare` | A factual statement made by the actor | declared → corrected / expired |
| `attest` | An operational fact affirmed by an operator | attested → corrected / superseded |
| `authorize` | Narrow permission bound to one protected action | authorized → consumed / expired |

The DSL is intentionally verbal:

```ruby
Clickwrap.policy :example do
  agree_to :terms
  acknowledge :privacy_notice
  consent_to :product_updates, optional: true, withdrawal_path: "/settings/privacy"
  declare :information_is_accurate
  attest :bank_transfer_was_accepted
  authorize :withdrawal, one_time: true, valid_for: 10.minutes

  retain_with :ordinary_agreement_evidence
end
```

The policy compiler rejects incoherent combinations at boot, in full sentences that tell you what's wrong and what to do about it: a one-time authorization can't be indefinite, consent needs a withdrawal path, and withdrawing future consent never rewrites a historical agreement.

## Protect an action with its evidence

`capture_and!` is the gem's signature move. In one supported database transaction it verifies the presentation, appends the evidence event, yields to your domain action, records the outcome, and commits both together:

Declare the exact post-action snapshot once. The callback receives the value
returned by the protected-action block—not the pre-action subject—and
`Clickwrap.protected_outcome` owns the stable reference and canonical
fingerprint:

```ruby
Clickwrap.policy :withdrawal_authorization do
  authorize :withdrawal,
    one_time: true,
    valid_for: 10.minutes,
    protected_outcome_version: "submitted-withdrawal-v1",
    record_protected_outcome_with: lambda { |withdrawal|
      Clickwrap.protected_outcome(
        action: :submitted,
        record: withdrawal,
        state: withdrawal.status,
        facts: {
          amount_in_cents: withdrawal.amount_cents,
          currency: withdrawal.currency,
          destination_reference: withdrawal.destination_reference
        }
      )
    }

  retain_with :regulated_evidence
end
```

```ruby
def create
  withdrawal = current_user.withdrawals.build(withdrawal_params)

  capture_clickwrap_and!(:withdrawal_authorization, actor: current_user, subject: withdrawal) do |pending_receipt|
    withdrawal.submit!(authorized_by_clickwrap_event: pending_receipt.event_id)
    withdrawal # the exact completed result given to the outcome recorder
  end

  redirect_to withdrawal
end
```

If the event write fails, the action rolls back. If your block raises, the event rolls back. Repeating an identical submission returns the original result without running the block twice; a conflicting replay fails with a stable `Clickwrap::ReplayRejected`. That remains true when the successful action itself changes the fingerprinted subject: once the signed nonce committed, replay verifies the frozen event context and exact answers instead of requiring the old pre-action state to still exist.

Link the row to the evidence that authorized it, so the connection survives years and engineers:

```bash
bin/rails generate clickwrap:link withdrawals && bin/rails db:migrate
```

```ruby
class Withdrawal < ApplicationRecord
  has_clickwrap_evidence policy: :withdrawal_authorization,
                         statement: :withdrawal,
                         actor: :user,
                         subject: :self
end

capture_clickwrap_and!(:withdrawal_authorization, actor: current_user, subject: withdrawal) do |pending_receipt|
  withdrawal.clickwrap_event_id = pending_receipt.event_id
  withdrawal.save!
  withdrawal
end

withdrawal.clickwrap_receipt.verify.success?   # one line, years later
```

And when a *person* causes the refusal — a stale token, a required box left unticked — every such case is one exception family carrying a sentence you can actually show them:

```ruby
def create
  # ... capture_clickwrap_and! as above ...
rescue Clickwrap::CaptureRefused => refusal
  redirect_to new_withdrawal_path, alert: refusal.user_facing_message, status: :see_other
end
```

Infrastructure failures stay outside that family and stay loud: an evidence write that fails refuses the protected action instead of being swallowed.

That atomicity has one exact boundary: Clickwrap's event and the protected domain
write must use the same database connection. If a host model uses another Rails
database/connection, its transaction cannot commit atomically with Clickwrap's
tables. Put Clickwrap on the same connection for database-local work; use an
explicit outbox/reconciliation design for another database or service.

For capture without a protected action, use `Clickwrap.capture!`. For external providers (Stripe, identity services) that can't share your database transaction, use `Clickwrap.authorize_external_action!` — a pending authorization plus idempotent outbox, so a provider timeout never becomes a fictional success or a double debit.

### One-time, subject-bound authorizations

```ruby
Clickwrap.policy :withdrawal_authorization do
  acknowledge :withdrawal_requirements

  declare :ride_exclusivity,
    subject_fingerprint_version: "covered-rides-v1",
    subject_fingerprint_with: ->(withdrawal) { withdrawal.covered_rides_fingerprint }

  authorize :withdrawal,
    one_time: true,
    valid_for: 10.minutes,
    requires: %i[withdrawal_requirements ride_exclusivity]

  retain_with :regulated_evidence
end
```

The authorization is locked and consumed in the same transaction as the withdrawal. Another withdrawal, a changed subject, a stale declaration, or a concurrent replay cannot reuse it. This is the difference between "the user once accepted something" and "this exact evidence authorized this exact operation."

## Ask readable questions everywhere

The actor proxy is the everyday API:

```ruby
user.clickwraps.current_for?(:signup)
user.clickwraps.agreed_to?(:terms)
user.clickwraps.consented_to?(:product_updates)
user.clickwraps.declared?(:non_professional_driver, subject: scheme)
user.clickwraps.authorized?(:withdrawal, subject: withdrawal)
```

When "no" needs an explanation, `verify` returns a structured result with a stable error symbol (`:declaration_expired`, `:consent_withdrawn`, `:wrong_subject`, …), a matching predicate, and a localized message — you never parse English to make an authorization decision. `Clickwrap.require!` raises a typed error carrying the same result. Service boundaries read aloud:

```ruby
preparation = Clickwrap.verify(:withdrawal_preparation, actor: user,
                               require_current_revision: true)
declaration = Clickwrap.verify(:ride_exclusivity, actor: user, subject: user,
                               require_current_revision: true)

declaration.stale_policy_revision?         # legal reworded it → re-ask
declaration.subject_fingerprint_mismatch?  # what it covers changed since capture
declaration.recorded_after?(preparation)   # ordering enforced, not assumed
```

`require_current_revision: true` fails evidence recorded under a superseded policy revision, so "we changed the wording, everyone re-accepts" is one keyword instead of a hand-rolled revision comparison.

Controller gates redirect users to a ready-made remediation screen and bring them back when they're done:

```ruby
class BillingController < ApplicationController
  requires_clickwrap :current_terms, only: :show
end
```

### Reacceptance when documents change

```ruby
Clickwrap.policy :current_terms do
  agree_to :terms, require_current_version: true

  retain_with :ordinary_agreement_evidence
end
```

Publish a new version and `current_for?` flips to `false` for everyone who accepted the old one. Preview the blast radius before you activate it:

```bash
bin/rails clickwrap:reacceptance:plan POLICY=current_terms
```

## Consent that can actually be withdrawn

Consent is purpose-specific, initially unselected, and separate from Terms:

```ruby
Clickwrap.policy :marketing_preferences do
  consent_to :product_updates, optional: true, withdrawal_path: "/settings/privacy"
  consent_to :partner_offers,  optional: true, withdrawal_path: "/settings/privacy"

  retain_with :marketing_consent_evidence
end
```

```ruby
Clickwrap.withdraw!(:product_updates, actor: current_user, http_request: request,
  because: "The user withdrew this purpose in privacy settings")
```

Withdrawal appends an event — it never deletes or mutates the historical grant. Declarations work the same way: they expire, get corrected, or get superseded through linked lifecycle events, without pretending the original statement never happened.

Seeds, imports, and admin-created accounts never fake a human click either — `Clickwrap.exempt!` records an explicit exemption with who created it and why, and exemptions never satisfy `agreed_to?`.

## Receipts show exactly what the application recorded

Every event has one canonical JSON receipt and one human-readable HTML projection:

```ruby
receipt = Clickwrap.receipt(event_id)
receipt.to_canonical_json
receipt.to_html
receipt.verify
```

An abbreviated receipt:

```json
{
  "schema": "clickwrap.receipt.v1",
  "event_id": "01K2Y8T5QY0N4V6N1H4G4CQY8J",
  "policy": { "key": "signup", "revision": "sha256:..." },
  "acts": [
    { "statement": "terms", "kind": "agreement", "action": "agreed" },
    { "statement": "privacy_notice", "kind": "acknowledgment", "action": "acknowledged" }
  ],
  "documents": [
    {
      "key": "terms",
      "version": "2026-08-15",
      "locale": "en",
      "source_digest": "sha256:...",
      "rendered_digest": "sha256:..."
    }
  ],
  "presentation": {
    "manifest_digest": "sha256:...",
    "submit_button_text": "Create account",
    "offered_at": "2026-08-15T12:34:56.123456Z"
  },
  "integrity": { "digest_algorithm": "sha256", "receipt_digest": "sha256:..." }
}
```

Verify it inside the app, or completely outside it with the bundled CLI:

```bash
clickwrap verify receipt.json --documents ./receipt-documents
```

Golden fixtures make a verifier regression for any released receipt schema fail the test suite.

With the engine mounted, users can view and download their own receipts, and operator access is always host-authorized. Read the [receipts and verification guide](guides/receipts-and-verification.md) for exports, bundles, and what each verification tier does and doesn't establish.

## Request evidence is off by default

`clickwrap` always records its event ID, server time, capture channel, and policy version. It records **no** IP addresses, browser user-agents, or IP geolocation unless a policy names the field with a purpose and a retention rule:

```ruby
Clickwrap.policy :regulated_authorization do
  authorize :regulated_action, one_time: true, valid_for: 10.minutes

  record_ip_address(
    encrypted: true,
    retain_until: :regulated_evidence_retention_ends,
    because: "Investigate account compromise and disputes about this action"
  )

  retain_with :regulated_evidence
end
```

Recorded values live in a separately encrypted annex with their own retention, so
they can be deleted later without rewriting the core event payload. Core payloads
have their own reviewed disposition path and leave a digest-linked tombstone.
There is deliberately no `gdpr_compliant_mode` or `maximum_evidence` switch —
every field is named individually, in plain English.

For IP geolocation, [`trackdown`](https://github.com/rameerez/trackdown) is the optional official resolver:

```ruby
config.ip_geolocation_resolver = Clickwrap::IpGeolocation::TrackdownResolver.new
```

The [request evidence guide](guides/request-evidence.md) covers every field, the provenance model, and the privacy boundaries.

## Retention, deletion, and legal holds

Every policy chooses an application-defined retention class:

```ruby
Clickwrap.retention :ordinary_agreement_evidence do
  retain_core_event_for 6.years
  delete_recorded_ip_address_after 90.days
  delete_recorded_browser_user_agent_after 90.days
end
```

Disposition is previewed, planned, and applied explicitly — and rechecked at apply time, so a newly placed legal hold or changed policy stops a stale plan:

```bash
bin/rails clickwrap:retention:plan
bin/rails clickwrap:retention:apply PLAN=01K2Y8T5QY0N4V6N1H4G4CQY8J
```

Destructive methods say exactly what they delete (`Clickwrap.delete_recorded_ip_address!`), deletions append a disposition event, and deleting a user account never silently cascades evidence away. Each event keeps the schedule recorded when that event was created; linked lifecycle events do not inherit their root's elapsed time or get deleted merely because the root became due. Legal holds pause disposition and are recorded through named append/release transitions. Details in the [retention and legal holds guide](guides/retention-and-legal-holds.md).

## Progressive integrity, honestly labeled

Start useful with an ordinary Rails database; add assurance without changing the capture API:

| Tier | What it adds |
|---|---|
| Baseline | Canonical receipts, immutable snapshots, SHA-256 digests, standalone verifier |
| Database hardening | Adapter-specific update/delete protections |
| Chained history | Per-tenant event chains and checkpoints |
| Independent anchoring | A verified publication of an exact event-chain snapshot outside the primary database |
| Third-party timestamps | A provider token over an exact event digest, with the adapter's verification result |

Each tier states exactly what threat it addresses. A local hash is never called tamper-proof, server time is never called trusted time, and an IP address is never called identity. The [integrity guide](guides/integrity.md) has the threat model.

```bash
bin/rails clickwrap:verify        # verify continuously in production
```

## Works with Devise, Rails authentication, Hotwire, and APIs

The installer detects your authentication stack and generates an explicit adapter — not a hidden `after_create` callback:

```ruby
# Devise
class Users::RegistrationsController < Devise::RegistrationsController
  clickwraps_registration_with :signup
end
```

```ruby
# Rails authentication generator
register_with_clickwrap :signup, user: @user do
  @user.save!
end
```

Both make account activation and its evidence commit together, with a prospective-actor flow that's honest about the fact that no authenticated user exists yet at render time.

During a legacy migration, keep a required dual-write inside that same
transaction without replacing Devise's controller action:

```ruby
class Users::RegistrationsController < Devise::RegistrationsController
  clickwraps_registration_with :signup,
    after_account_is_saved_inside_transaction: :record_legacy_acceptance!

  private

  def record_legacy_acceptance!(account:, pending_receipt:)
    account.terms_acceptances.create!(
      clickwrap_event_id: pending_receipt.event_id,
      accepted_at: Time.current
    )
  end
end
```

If that required legacy write fails, the account and Clickwrap evidence roll
back with it. Remove the hook after parity and cutover are proved.

Everything is server-rendered HTML: full-page requests, Turbo Drive and Frames, no-JavaScript validation, and Hotwire Native all work with the same helper. JSON/API clients use `Clickwrap.present` to get the server-owned manifest and submit answers with the signed token. Views are ejectable with `bin/rails generate clickwrap:views`, or build fully custom UI on `Clickwrap.present` plus the view helpers — `clickwrap_presentation_token_field`, `clickwrap_statement_check_box`, `clickwrap_statement_radio_button`, and `clickwrap_submit_button` own the envelope name, the control names, and a call to action worded by the signed manifest itself, while you own every class and wrapper around them. The [integrating guide](guides/integrating.md#4-custom-surfaces--the-three-contracts) shows a full custom surface.

### Works with `organizations`

A human `User` can bind an `Organizations::Organization` without collapsing
the two identities:

```ruby
Clickwrap.policy :organization_terms do
  agree_to :organization_terms
  permit_acting_for_organization when_actor_is_at_least: :admin
  retain_with :ordinary_agreement_evidence
end
```

```erb
<%= form.clickwrap :organization_terms,
      acting_for: current_organization,
      submit: "Accept for #{current_organization.name}" %>
```

Authority is reread from the membership at submit, and the receipt records the
human actor, represented organization, actual membership role, authority
criterion, source, and verification time separately. Clickwrap records the
configured authorization fact; it does not decide whether that role is legally
sufficient. See [Binding an organization through a human actor](guides/organizations.md).

## Recipes

Two situations come up in almost every real app. Here's exactly how to handle both.

### "Accept the new Terms to continue" — wall the app until updated Terms are accepted

You know how Apple Developer releases new terms every few months and walls off the entire dashboard until you accept them? Same pattern here: legal ships a new version of your Terms, and nobody uses your app again until they've agreed to it. Accepting the new version supersedes the old one — and you keep a receipt for every version each user ever agreed to, so you always know exactly who agreed to exactly what, and when.

Bump the document version when the new text ships:

```ruby
# config/clickwrap.rb
Clickwrap.document :terms,
  version: "2026-11-01",   # was "2026-08-15" — new text means a new version
  from: Rails.root.join("app/content/legal/terms.md")

Clickwrap.policy :current_terms do
  agree_to :terms, require_current_version: true

  retain_with :ordinary_agreement_evidence
end
```

Mount the built-in acceptance screen and wall the app:

```ruby
# config/routes.rb
mount Clickwrap::Engine => "/agreements"
```

```ruby
class ApplicationController < ActionController::Base
  # Nobody gets past this until they've accepted the current Terms. Clickwrap's
  # own acceptance, receipt, withdrawal, and document screens stay reachable
  # automatically, so this cannot redirect-loop its remediation page.
  requires_clickwrap :current_terms
end
```

Publish the new version and every signed-in user gets redirected to the acceptance screen on their next request — and sent back to wherever they were going the moment they accept. Preview the blast radius before you activate it:

```bash
bin/rails clickwrap:reacceptance:plan POLICY=current_terms
```

What you get for free: the new acceptance supersedes the old one (`agreed → superseded`) without rewriting anything, and every receipt pins the exact version, locale, and byte digest of what each user agreed to — so "which exact Terms did this person accept, and when?" stays answerable years later.

Want to wall off only *parts* of the app instead? Gates are per-controller and per-action, and different areas can require different policies:

```ruby
class BillingController < ApplicationController
  requires_clickwrap :current_terms
end

class Api::DashboardController < ApplicationController
  requires_clickwrap :developer_terms, only: %i[show update]
end
```

### "I agree" before the account even exists — signup, Google sign-in

At signup, people click "I agree" before they have an account with you: there's no `current_user` to hang the acceptance on yet, and the acceptance has to survive account creation. `clickwrap` models this honestly as a *prospective-actor* flow — the acceptance binds to a short-lived signed registration flow, then the account and its acceptance evidence commit in one database transaction, and the receipt records that this was an account registration (not an authenticated session).

For plain email/password signup, the Devise and Rails-authentication adapters above already do all of this — `form.clickwrap :signup` in your signup form is the whole integration.

For Google sign-in (OAuth, One Tap), the click happens on Google's side, so put the acceptance on a "finish creating your account" screen after the callback:

```ruby
# The OAuth callback doesn't create the account yet — it stashes what Google
# said and sends the person to finish signing up.
def google
  session[:pending_oauth] = request.env["omniauth.auth"].slice("provider", "uid", "info")
  redirect_to new_finish_signup_path
end
```

```erb
<%# The finish screen: name and email prefilled from Google, plus your Terms. %>
<%= form_with model: @user, url: finish_signup_path do |form| %>
  <%= form.clickwrap :signup, submit: "Create account" %>
<% end %>
```

```ruby
def create
  @user = User.new(user_attributes_from(session[:pending_oauth]))

  register_with_clickwrap :signup, user: @user do
    @user.save!   # account + acceptance commit together, or neither happens
  end

  session.delete(:pending_oauth)
  sign_in @user
  redirect_to root_path
end
```

The registration flow lives in your session and the presentation token is valid for two hours by default, so both comfortably survive the round-trip to Google and back. One thing `clickwrap` will not do, on purpose: record an agreement from the OAuth callback alone. "By continuing you agree" with no affirmative act isn't evidence of anything — a real acceptance step has to happen somewhere, and the finish screen is where it belongs.

### One person accepts for the whole company — organization agreements

Your customer is a company — but companies don't click checkboxes, people do. When an admin accepts your business terms "for Acme Inc.", two facts matter and must never blur into each other: the *organization* is the party the terms are for, and a *specific human* performed the acceptance on its behalf. Years later, the question is always the same: exactly which person accepted for the company, and what authority did they have when they did?

Declare in the policy who is allowed to accept for an organization — membership alone is deliberately not enough:

```ruby
Clickwrap.policy :organization_terms do
  agree_to :business_terms

  permit_acting_for_organization when_actor_is_at_least: :admin

  retain_with :ordinary_agreement_evidence
end
```

Make the represented company conspicuous in the UI, and pass it as `acting_for:`:

```erb
<p>You are accepting these terms for <strong><%= current_organization.name %></strong>.</p>

<%= form.clickwrap :organization_terms,
      acting_for: current_organization,
      submit: "Accept for #{current_organization.name}" %>
```

Then capture the acceptance and stamp the organization in one transaction, so the rest of your app can ask a plain domain question:

```ruby
def create
  organization = current_organization

  capture_clickwrap_and!(:organization_terms, acting_for: organization) do |pending_receipt|
    organization.update!(terms_accepted_with_clickwrap_event_id: pending_receipt.event_id)
  end

  redirect_to organization_settings_path
end
```

At submit, `clickwrap` requires a current membership in that exact organization, rereads and locks the membership role *inside* the capture transaction (an admin demoted between render and submit is refused), and rejects a token rendered for one organization and submitted for another. The receipt then records the human actor, the represented organization, the actual membership role, the authority criterion, and the verification time — all as separate facts. An organizational acceptance never quietly answers a personal one, and vice versa:

```ruby
user.clickwraps.current_for?(:organization_terms, acting_for: organization)  # => true
user.clickwraps.current_for?(:organization_terms)                            # => false
```

That receipt is exactly what you'll be asked to produce if the agreement is ever disputed: who accepted, for which company, in what role, verified when. Whether that role was *sufficient to bind the company* is a question for your counsel when they choose the `when_actor_is_at_least:` criterion — `clickwrap` records the facts that answer it. Works out of the box with the [`organizations`](https://github.com/rameerez/organizations) gem, or with your own authority model via a registered adapter. The [organizations guide](guides/organizations.md) has the full walkthrough.

## Testing your integration

Documents must be published in the test database too — presentations refuse unpublished documents in tests exactly as in production:

```ruby
# test/test_helper.rb
class ActiveSupport::TestCase
  include Clickwrap::TestHelpers
  parallelize_setup { Clickwrap.publish! }  # once per parallel worker...
end
Clickwrap.publish!                           # ...and once per process
```

```ruby
receipt = capture_clickwrap(:signup, actor: user, answers: { terms: true, privacy_notice: true })

assert_clickwrap_current :signup, actor: user
assert_clickwrap_agreed_to :terms, actor: user
assert_clickwrap_receipt_verifies receipt
```

Integration tests can't fabricate a signed presentation token by hand — that's the point — so they read it off the rendered page the way a browser does:

```ruby
post user_registration_path, params: {
  user: { email: "person@example.com", password: "a-real-password" },
  **clickwrap_params_from(new_user_registration_path)   # GET the page, affirm everything
}

# Decline one statement instead:
declined = clickwrap_params_from(new_user_registration_path, answers: { terms: false })

# Choice statements submit their real rendered values. By default the helper
# selects the first offered radio choice; name a different choice explicitly:
contractor = clickwrap_params_from(
  new_user_registration_path,
  answers: { employment_kind: "contractor" }
)
```

Checkbox statements default to their affirmative value. Radio statements
default to the first choice rendered by the application, so tests exercise a
value the server actually offered instead of a fabricated checkbox value.
Pass the exact choice key when the choice matters. For a conventional
`yes`/`no` radio group, `false` selects `no`; explicit choice keys remain the
clearest option for domain-specific choices.

If one page renders several independent Clickwrap forms, select the exact form;
the helper refuses an ambiguous page instead of combining one form's token with
another form's answers:

```ruby
submission = clickwrap_submission_params_from(
  response,
  form_css_selector: "form[action='/withdrawals/confirm']"
)
```

Fault injection proves the atomicity claim in your own suite:

```ruby
Clickwrap::Testing.fail_next_event_write do
  assert_raises(Clickwrap::EventWriteFailed) { perform_signup }
end
assert_not User.exists?(email: "person@example.com")
```

## Configuration

The generated initializer is fully annotated and every setting reads like a sentence. The essentials:

```ruby
# config/initializers/clickwrap.rb
Clickwrap.configure do |config|
  config.actor_class_name = "User"
  config.current_actor_method_name = :current_user

  config.authorize_receipt_access_with = lambda do |controller, receipt|
    controller.current_user == receipt.actor
  end

  # Safe defaults: no IP address, browser user-agent, or IP geolocation is stored.
  # Enable fields per policy, each with a plain-English purpose and retention rule.

  # Optional hooks run only after evidence and domain state have committed:
  config.after_event_is_committed = ->(event) { }
end
```

Class names are strings resolved lazily for autoloading, and ambiguity fails at boot instead of becoming a surprising runtime default. Optional external integrations are explicit: anchoring and timestamping are off (`nil`) until an adapter is configured; optional hook procs have working no-op defaults; and geolocation/document integrations run only when their corresponding policy or storage choice asks for them.

## Operations

```bash
bin/rails clickwrap:doctor              # objective health report, never prints "compliant"
bin/rails clickwrap:publish             # freeze document snapshots (idempotent)
bin/rails clickwrap:verify              # verify event digests
bin/rails clickwrap:retention:plan      # preview disposition
bin/rails clickwrap:privacy:inventory   # every configured personal-data field, purpose, and rule
bin/rails clickwrap:import:fine_print   # migrate from FinePrint without inventing history
```

Migrating from FinePrint or a bare `accepted_terms_at` column? Clickwrap's importer appends provenance-labeled events through its supported API: fields the old system never recorded stay `unknown` instead of being laundered into modern certainty. Direct database privileges remain outside that API's boundary. See the [migration guide](guides/migrating.md).

## Will this hold up in court?

Here's the honest version, in plain words, because you deserve better than marketing copy on this question.

Electronic form alone is not a reason to deny a contract legal effect under the US E-SIGN Act
([15 U.S.C. § 7001](https://www.law.cornell.edu/uscode/text/15/7001)), and the EU's eIDAS
regulation says an electronic signature may not be denied legal effect or admissibility solely
because it is electronic or not qualified ([Regulation 910/2014, Article 25](https://eur-lex.europa.eu/eli/reg/2014/910/2024-05-20/eng)).
That does not decide what happens around the control in a particular downstream application:

**Courts read your whole page, not your checkbox.** In *Berman v. Freedom Financial Network* (a 2022 Ninth Circuit decision, [opinion](https://cdn.ca9.uscourts.gov/datastore/opinions/2022/04/05/20-16900.pdf)), the terms lost: the notice was in tiny gray font, the links to the terms didn't look like links, and the button said "Continue" without mentioning them — even though an acceptance flow existed. Other federal appeals courts run the same whole-interface analysis (*[Tejon v. Zeus Networks](https://media.ca11.uscourts.gov/opinions/pub/files/202411114.pdf)*, *[Toth v. Everly Well](https://www.ca1.uscourts.gov/sites/ca1/files/opnfiles/23-1727P-01A.pdf)*). Placement, font size, contrast, clutter, the words on the button: all decided by *your* page. `clickwrap` renders one accessible, initially-unselected component and records exactly what that component said — it cannot see, or fix, the rest of your screen.

**The words in your documents matter more than the click.** In the EU, an unfair term in a consumer contract doesn't bind the consumer even when the assent flow was otherwise effective ([Directive 93/13/EEC](https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=celex%3A31993L0013)). A strong record of acceptance does not change the underlying term. The gem records your words; it can't make them fair.

**Who acted, and in which capacity.** `clickwrap` records the actor and the authentication and
authority facts your application supplies; it does not establish identity, capacity, or legal
authority. For an organization, it keeps the human actor distinct from the represented party and
records the role or permission criterion your application checked—[see the recipe](#one-person-accepts-for-the-whole-company--organization-agreements).

**Your jurisdiction and your document type.** The US E-SIGN Act expressly excludes categories
including wills, specified family-law matters, and specified notices
([15 U.S.C. § 7003](https://www.law.cornell.edu/uscode/text/15/7003)). In the EU, a
*qualified* electronic signature has the equivalent legal effect of a handwritten signature;
Article 25 separately says other electronic signatures may not be denied legal effect or
admissibility solely because they are electronic or not qualified
([eIDAS Article 25](https://eur-lex.europa.eu/eli/reg/2014/910/2024-05-20/eng)).
This gem does not produce or claim a qualified electronic signature.

**And GDPR consent is its own animal.** Consent has to be demonstrable and withdrawable ([GDPR Article 7](https://eur-lex.europa.eu/eli/reg/2016/679/art_7/oj/eng)) — `clickwrap` gives you both mechanics — but merely acknowledging a privacy notice is not consent (regulator guidance from Spain's AEPD, [FAQ 02.48](https://www.aepd.es/preguntas-frecuentes/2-tus-obligaciones-como-responsable-del-tratamiento/6-el-deber-de-informacion/FAQ-0248-sobre-si-el-usuario-tiene-que-dar-consentimiento-a-clausula-de-privacidad)). That's why `acknowledge` and `consent_to` are different verbs here, with different lifecycles.

Notice what's left after all of that: **evidence**. Those opinions examine what interface the
application offered and what action it recorded—not whether checkboxes are valid in the abstract.
Which exact version of the terms did the server bind to the form? What did the presentation
manifest say beside the control? Was the control initially unselected? Which explicit submission
did the server accept? Was consent later withdrawn? Most apps genuinely cannot reconstruct those
application-side facts; `clickwrap` exists so you can, with a receipt verifiable without the
producing application's source code. It still does not prove that a person perceived or
understood the interface.

That's also why nothing in this gem prints "legally binding" or "court-proof": those are conclusions a court reaches about *your* agreement, under *your* jurisdiction's law, looking at *your* whole page and *your* terms. The gem's job is narrower and more useful — making sure that when that day comes, your lawyer is holding the receipt.

## What `clickwrap` is *not*

This gem provides evidence mechanics — excellent ones — and nothing else. It does not:

- draft or approve legal documents, or decide whether a change is "material";
- claim compliance, enforceability, admissibility, or "court-proof" anything;
- verify identity or age, or decide whether a configured role or permission is
  legally sufficient to bind an organization (identity, KYC, and legal capacity
  belong elsewhere);
- become DocuSign, a notary, a cookie CMP, or a contract-lifecycle platform;
- call a local hash tamper-proof, server time trusted time, or an IP address a person;
- hide data collection behind a `compliant: true` switch.

Your application and its counsel own the legal text, lawful basis, retention periods, and jurisdiction-specific requirements. `clickwrap` makes configured decisions executable and traceable in evidence—it doesn't make them for you.

## FAQ

### Is this an electronic-signature gem?

It captures electronic evidence of explicit actions and can import provider signature receipts. It does not call a checkbox a qualified electronic signature.

### Does the user have to scroll through the document?

No — and `clickwrap` never equates scrolling with reading. It makes documents available before action and records the exact presentation. A policy can require an observed open/review interaction if your app truly needs one.

### Should I record IP addresses?

Only for policies with a real, documented purpose. They corroborate request context; they don't prove identity or location. Everything defaults off.

### Can I keep my domain models?

Yes, and you should. `clickwrap` owns presentation, evidence, lifecycle, and receipts — not your payout, eligibility, or employment rules.

### Is this GDPR compliant?

No gem can answer that. `clickwrap` gives you privacy-aware mechanisms, truthful defaults, and an inventory of exactly what you configured. Lawful basis, necessity, and data-subject rights remain yours.

## Compatibility

- Ruby 3.2+, Rails 7.1 through 8.x
- PostgreSQL, SQLite, and MySQL for all portable core behavior (hardening is adapter-specific and labeled)
- Integer and UUID primary keys; Devise and Rails authentication both optional
- Runtime dependencies are only the Rails components the gem actually uses (`activerecord`, `actionpack`, `actionview`, `activesupport`, `railties`) — never Redis, a job backend, a JS runtime, or an external service

Persisted evidence gets a stricter promise than semver: every released receipt schema has a permanent golden fixture, new versions keep verifying old receipts, and released migrations are never edited underneath your app — see [Stability and upgrade promise](#stability-and-upgrade-promise).

## Stability and upgrade promise

`clickwrap` follows semantic versioning for its Ruby APIs. Evidence formats are stricter: a format change gets a new explicit schema and verifier, never a silent reinterpretation; upgrade generators add migrations and report their effects; and deprecations name their replacement and remain executable for a documented window.

## Development

```bash
bin/setup
bundle exec rake test
bundle exec rubocop
```

The project uses Minitest with a dummy Rails app, SimpleCov, RuboCop, Appraisal matrices, and SQLite/PostgreSQL/MySQL CI lanes. Fault-injection, concurrency, replay, stale-token, disposition, and golden-receipt tests are load-bearing, not extras.

## Contributing

Bug reports and focused pull requests are welcome at https://github.com/rameerez/clickwrap. Please run `bundle exec rake test` and `bundle exec rubocop` first.

Two kinds of change need extra care: anything touching public vocabulary or an evidence claim (docs change alongside code, plus a note on receipts already written), and anything touching canonicalization, receipt schemas, digests, or migrations — released evidence formats are permanent. Security reports go through [`SECURITY.md`](SECURITY.md), privately.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
