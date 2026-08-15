# ☑️ `clickwrap` — trustworthy agreements, consent, declarations, and authorizations for Rails

[![Gem Version](https://badge.fury.io/rb/clickwrap.svg)](https://badge.fury.io/rb/clickwrap) [![Build Status](https://github.com/rameerez/clickwrap/workflows/Tests/badge.svg)](https://github.com/rameerez/clickwrap/actions)

> [!IMPORTANT]
> **Status: built and tested, not yet proven in production.** Everything described below is implemented and covered by the test suite. What has *not* happened yet is the part that decides whether this gem is worth depending on: the three proof integrations, a usability test with a developer who has never seen it, and a legal review of the default wording and receipt claims. Those gates are tracked in [`docs/strategy/03-readiness-market-and-next-steps.md`](docs/strategy/03-readiness-market-and-next-steps.md). Until they pass, treat this as a release candidate for evaluation rather than something to put under a payout flow. The two areas most likely to change are the exact public names and the receipt schema; the [stability promise](#stability-and-upgrade-promise) applies from 0.1.0 onward.

`clickwrap` is the missing evidence-and-assent layer for Rails.

It makes ordinary Terms acceptance and its action one beautiful form-builder call:

```erb
<%= form.clickwrap :signup, submit: "Create account" %>
```

And it grows with you all the way to expiring declarations, withdrawable consent, one-time authorizations, exact historical receipts, transaction-bound evidence, retention, legal holds, and independently verifiable exports—without making the simple path feel complicated.

```ruby
receipt = Clickwrap.capture_and!(
  :withdrawal_authorization,
  actor: current_user,
  subject: withdrawal,
  http_request: request,
  submission: clickwrap_submission
) do |pending_receipt|
  withdrawal.submit!(authorized_by_clickwrap_event: pending_receipt.event_id)
end
```

If evidence cannot be recorded, the protected database action does not happen. If the action fails, the evidence does not pretend it succeeded.

No JavaScript package. No Redis. No external account. No legal-document vendor. No required per-event API call. No required background job. Just Rails, your database, and an API that reads like plain English.

> [!TIP]
> **Building a new Rails product?** [RailsFast](https://railsfast.com/?ref=clickwrap) ships the conventional signup integration, so new applications start with versioned Terms, a distinct Privacy Notice acknowledgment, atomic evidence, and receipts instead of inventing an `accepted_terms_at` column.

## The five-minute version

Install it:

```bash
bundle add clickwrap
bin/rails generate clickwrap:install
bin/rails db:migrate
```

The installer detects Rails authentication versus Devise, integer versus UUID primary keys, and the database adapter. It generates adaptive migrations, one annotated initializer, a conventional signup policy, and the correct explicit authentication integration. It never invents legal text or silently guesses an ambiguous actor model.

Point the generated policy at the exact documents your application already owns:

```ruby
# config/clickwrap.rb
Clickwrap.document :terms,
  version: "2026-08-15",
  from: Rails.root.join("app/content/legal/terms.md")

Clickwrap.document :privacy_notice,
  version: "2026-08-15",
  from: Rails.root.join("app/content/legal/privacy.md")

Clickwrap.policy :signup do
  agree_to :terms
  acknowledge :privacy_notice
end
```

Tell Clickwrap which records can act:

```ruby
# app/models/user.rb
class User < ApplicationRecord
  has_clickwraps
end
```

Render the policy and its bound submit action:

```erb
<%= form_with model: resource do |form| %>
  <%# email, password, etc. %>

  <%= form.clickwrap :signup, submit: "Create account" %>
<% end %>
```

Publish immutable snapshots and boot the app:

```bash
bin/rails clickwrap:publish
```

That is the whole conventional integration. The helper renders the initially unselected controls and the submit button as one presentation, so the exact call to action in the signed manifest is the one the user can press. The generated Rails-authentication or Devise adapter saves the account and required evidence in one database transaction.

At first render there is no persisted user yet. Clickwrap does not pretend otherwise: it binds the presentation to a short-lived prospective-actor registration flow, then the authentication adapter binds the resulting account to that presentation inside the same transaction. The receipt identifies the attribution method as account registration, not an authenticated session.

From that moment on:

```ruby
user.clickwraps.agreed_to?(:terms)                  # => true
user.clickwraps.acknowledged?(:privacy_notice)      # => true
user.clickwraps.current_for?(:signup)               # => true

receipt = user.clickwraps.receipts.last
receipt.event_id                                    # => "01K2..."
receipt.verify.success?                             # => true
receipt.to_canonical_json
receipt.to_html
```

Clickwrap preserves the exact document bytes and digests, policy revision, assertion and link text, choices, submit-button text, locale, presentation manifest, actor, authentication context, server time, lifecycle, and resulting protected action. Optional request evidence stays off until you explicitly ask for it.

Everything below is depth, not setup tax.

If you came for one particular job:

- start with [the form helper](#the-form-helper) for ordinary Rails forms;
- use [`capture_and!`](#capture-evidence-and-the-protected-action-together) for consequential same-database actions;
- read [consent](#consent-that-can-actually-be-withdrawn), [declarations](#expiring-and-corrected-declarations), or [one-time authorization](#narrow-one-time-authorizations) for richer lifecycles;
- configure [optional request evidence](#optional-request-evidence-private-by-default) only after reading its privacy boundaries;
- use [receipts](#receipts-answer-show-me-exactly-what-happened), [retention](#retention-deletion-and-legal-holds-are-first-class), and [integrity tiers](#progressive-honest-integrity) when the audit trail matters; or
- jump to [the complete initializer](#the-generated-initializer-explains-itself) to see every default together.

---

## Why this gem exists

A checkbox is easy. Answering these questions three years later is not:

- Which exact version did this person agree to?
- What did the page actually say beside the control and submit button?
- Was the checkbox initially empty and required on the server?
- Did the account, payout, declaration, or provider handoff succeed without its evidence?
- Was this consent later withdrawn?
- Had this declaration expired?
- Did this authorization cover this exact transaction, or was it replayed for another one?
- Can an auditor reproduce the document without checking out historical application code?
- Can optional personal request evidence be deleted without rewriting the historical event?
- Can the exported receipt still be verified after several gem and Rails upgrades?

Most applications eventually accumulate some combination of:

```text
accepted_terms_at
terms_version
an audit log
a few hidden form fields
an after_create callback
some IP-address columns
several domain-specific "confirmed_at" timestamps
```

Each part looks reasonable alone. Together they produce partial writes, client-owned policy decisions, mutable history, confused consent semantics, and evidence that only the original engineer can explain.

`clickwrap` turns that recurring plumbing into one coherent Rails primitive:

```text
immutable document
      +
server-owned policy
      +
exact presentation
      +
explicit actor action
      +
atomic protected outcome
      +
append-only lifecycle
      =
reproducible receipt
```

It is intentionally not a “one checkbox makes anything legal” gem. It provides excellent evidence mechanics. Your application and counsel still own the words, lawful basis, fairness, capacity, authority, jurisdiction, formalities, and retention decisions.

## Six verbs, six honest meanings

Not every checkbox is “consent,” and not every timestamp is a “signature.” Clickwrap gives each act the lifecycle it actually needs:

| Policy verb | Evidence kind | Meaning | Typical lifecycle |
|---|---|---|---|
| `agree_to` | `agreement` | Assent to contractual terms | agreed → superseded/new version |
| `acknowledge` | `acknowledgment` | Affirmative receipt or awareness of a notice/risk | acknowledged → superseded/expired |
| `consent_to` | `consent` | Purpose-specific permission where consent is the host’s chosen basis | granted → withdrawn/renewed/scope changed |
| `declare` | `declaration` | A factual statement made by the actor | declared → corrected/superseded/expired |
| `attest` | `attestation` | An operational fact affirmed by an authorized actor | attested → corrected/superseded |
| `authorize` | `authorization` | Narrow permission bound to a protected action | authorized → consumed/revoked/expired |

The DSL is intentionally verbal:

```ruby
Clickwrap.policy :example do
  agree_to :terms
  acknowledge :privacy_notice
  consent_to :product_updates, optional: true
  declare :information_is_accurate
  attest :bank_transfer_was_accepted
  authorize :withdrawal, one_time: true, valid_for: 10.minutes
end
```

The policy compiler rejects incoherent combinations at boot. A one-time authorization cannot be indefinite. Consent needs a withdrawal path. A declaration can expire without pretending the original statement was false. Withdrawing future consent never rewrites a historical agreement.

This taxonomy is product design, not statutory vocabulary. The host chooses the correct kind with appropriate legal/product review.

One submitted policy produces one root evidence event and one receipt, even when the policy contains several acts. Each act keeps its own kind, statement, documents, answer, and lifecycle under that root event. That gives the protected domain action one stable `event_id` to reference without flattening “agreed to Terms” and “acknowledged the Privacy Notice” into the same meaning.

## Documents are immutable, reproducible records

Define a logical document once and publish as many immutable versions and locales as needed:

```ruby
Clickwrap.document :terms,
  version: "2026-08-15",
  locale: :en,
  effective_at: Time.utc(2026, 8, 15),
  from: Rails.root.join("app/content/legal/terms.en.md")

Clickwrap.document :terms,
  version: "2026-08-15",
  locale: :es,
  effective_at: Time.utc(2026, 8, 15),
  from: Rails.root.join("app/content/legal/terms.es.md")
```

Publish them during development or deployment:

```bash
bin/rails clickwrap:publish
```

Publishing:

- reads the exact bytes;
- records media type and locale;
- calculates a versioned digest;
- snapshots the exact rendered representation when a source format is transformed for display;
- records the renderer and sanitizer identity/version used for that representation;
- freezes a database snapshot;
- compiles and freezes every policy revision that references it; and
- refuses to reuse a version label for different bytes.

The task is idempotent. A changed document requires a new version. Export never fetches a mutable live URL and calls it historical evidence.

Preview the plan without writing:

```bash
bin/rails clickwrap:publish:plan
```

The default database store is deliberately boring and complete. Larger applications can switch document bodies to content-addressed Active Storage or object-lock storage while keeping the same digest and receipt contract:

```ruby
config.store_document_contents_in = :active_storage
```

Every storage adapter must return immutable bytes plus a verifiable digest. A URL alone is never a document version.

Markdown, HTML, plain text, and attached files are evidence inputs, not trusted markup by accident. The reference renderer sanitizes display HTML. A custom renderer must return the exact rendered bytes it offered, and Clickwrap stores their digest alongside the original-source digest. That preserves the distinction between “this Markdown file existed” and “this rendered representation was offered.”

## Policies are server-owned offers

A policy declares what the server will present and accept. The browser may answer; it may never choose the policy, document version, validity, subject, retention, or request-evidence fields.

```ruby
Clickwrap.policy :driver_declaration do
  declare :non_professional_driver,
    document: :driver_declaration,
    statement: "I declare that I drive privately and not as a professional driver.",
    valid_for: 1.year,
    subject_fingerprint_with: ->(scheme) { scheme.evidence_fingerprint }

  retain_with :regulated_evidence
end
```

Policies compile at boot. Clickwrap fails loudly for:

- missing documents or locales;
- duplicate statement keys;
- invalid lifecycle options;
- a consent policy without a configured withdrawal path;
- a one-time authorization without expiry/consumption behavior;
- request evidence without a named present purpose and retention decision;
- a subject-bound policy without a subject fingerprint; or
- a changed compiled policy reusing the same revision.

Policy revisions are defined pleasantly in Ruby and persisted as frozen canonical snapshots. Historical receipts do not need current source code to explain what revision meant.

Every human-facing value can be a literal, an I18n key, or a locale map. Clickwrap resolves it before presentation, fails closed when a required translation is missing, and stores the resolved text and locale—not merely an I18n key whose meaning may change later.

### Reacceptance is explicit

New document bytes do not silently reinterpret old evidence:

```ruby
Clickwrap.policy :current_terms do
  agree_to :terms, require_current_version: true
end
```

```ruby
Clickwrap.required?(:current_terms, actor: user)     # => true after a new version publishes
user.clickwraps.current_for?(:current_terms)         # => false
```

The application decides which change is material. Clickwrap enforces the rule it is given; it does not decide legal materiality.

Before activating a new required version, operators can preview its effect:

```bash
bin/rails clickwrap:reacceptance:plan POLICY=current_terms
```

The plan reports affected actor counts and configured remediation routes without emailing anyone, changing current state, or calling the change “material.” Scheduled versions become presentable only at their explicit `effective_at`; correcting a published mistake means publishing a new version or stopping future presentation with an append-only operator reason, never replacing historical bytes.

## Presentation manifests stop render-to-submit substitution

`form.clickwrap` does more than render controls. It creates a short-lived presentation manifest bound to an actor or prospective-actor flow, subject, and tenant containing:

- policy key and frozen revision;
- document versions, locales, and digests;
- exact statements, labels, link labels/targets, choices, required state, and CTA text;
- actor, tenant, and subject bindings;
- subject fingerprint;
- template, application, and gem versions;
- capture channel;
- issue time, expiry, and one-use nonce; and
- a canonical manifest digest.

The browser receives a signed presentation token. On submit, Clickwrap verifies it against current server policy and rejects stale, swapped, expired, cross-account, cross-tenant, or cross-subject tokens.

A deploy between GET and POST never causes the server to record a version the actor was not offered. The policy either honors that still-valid presentation or asks the user to review the new one.

The default signed-manifest path performs no database write on GET. A high-assurance flow can explicitly retain pre-submit presentation attempts:

```ruby
Clickwrap.policy :regulated_authorization do
  persist_presentations_before_submission_for 30.days,
    because: "Investigate disputes about this regulated authorization"
  authorize :regulated_action, one_time: true, valid_for: 10.minutes
end
```

Persisted presentations carry their own purpose, access, abuse controls, and retention; an abandoned GET is labeled `presented_by_server`, never `accepted` or `seen_by_human`.

The receipt says exactly what this proves: the server generated and accepted a particular presentation manifest. It does not claim the person read the document, understood it, saw particular pixels, or received a legally sufficient interface in every jurisdiction.

### The form helper

The strongest happy path is one line because the component owns both the controls and the action whose wording it records:

```erb
<%= form.clickwrap :signup, submit: "Create account" %>
```

Submit options remain ordinary Rails:

```erb
<%= form.clickwrap :signup,
  actor: current_user,
  subject: @organization,
  locale: I18n.locale,
  submit: {
    text: "Create organization",
    class: "button button--primary",
    data: { turbo_submits_with: "Creating…" }
  } %>
```

The helper renders:

- real, initially unselected controls;
- kind-appropriate first-person language;
- obvious document links before the submit action;
- stable label/control/error associations;
- server errors and accessible error summaries;
- the signed presentation token; and
- no hidden IP address, browser user-agent, policy version, validity date, or other client-owned security decision.

HTML `required` is progressive enhancement. Server validation is always authoritative.

If your design system needs to render the action separately, use the deliberately explicit split API:

```erb
<%= form.clickwrap_fields :signup,
  submit_button_text: "Create account" %>

<%= form.submit "Create account" %>
```

The repeated text is intentional: it makes the evidence contract visible in code. Development and system-test assertions compare the declared text with the rendered submit control and reject a mismatch. The one-call API is preferred because it makes that class of drift impossible.

### Use the ready-made standalone remediation screen

Any policy can be completed outside its original flow:

```ruby
# config/routes.rb
mount Clickwrap::Engine => "/agreements"
```

```ruby
clickwrap_capture_path(:driver_declaration)
```

The engine provides actor-owned capture, receipt, consent-withdrawal, and document-history surfaces using your parent controller, layout, locale, and authorization callbacks. This makes a required agreement or declaration resolvable in place instead of becoming a dead end.

### Eject or fully own the UI

Copy the tested reference views:

```bash
bin/rails generate clickwrap:views
```

Your copies shadow the gem’s views. Tailwind, Bootstrap, ViewComponent, Phlex, custom design systems, and plain ERB are all welcome.

For a completely custom surface, ask the presenter for primitives rather than recreating hidden inputs:

```ruby
presentation = Clickwrap.present(
  :signup,
  actor: current_user,
  subject: nil,
  locale: I18n.locale,
  submit_button_text: "Create account"
)
```

```erb
<%= hidden_field_tag "clickwrap_submission[presentation_token]", presentation.token %>

<% presentation.statements.each do |statement| %>
  <%# Render statement.control_name, label, document links, choices and errors. %>
<% end %>
```

The development linter compares the submitted manifest with the policy/presenter contract and warns about missing statements, preselected consent, absent links, controls placed after the CTA, or unregistered custom copy. It reports objective problems; it never prints “legally compliant.”

## Capture evidence and the protected action together

For an existing actor in a normal Rails controller:

```ruby
def create
  withdrawal = current_user.withdrawals.build(withdrawal_params)

  receipt = capture_clickwrap_and!(
    :withdrawal_authorization,
    actor: current_user,
    subject: withdrawal
  ) do |pending_receipt|
    withdrawal.submit!(authorized_by_clickwrap_event: pending_receipt.event_id)
  end

  redirect_to withdrawal
end
```

The controller helper reads only the generated `clickwrap_submission` envelope and the current `http_request`. It delegates to the same public service API:

```ruby
receipt = Clickwrap.capture_and!(
  :withdrawal_authorization,
  actor: current_user,
  subject: withdrawal,
  http_request: request,
  submission: clickwrap_submission
) do |pending_receipt|
  withdrawal.submit!(authorized_by_clickwrap_event: pending_receipt.event_id)
end
```

Within one supported database transaction, Clickwrap:

1. verifies actor, tenant, subject, presentation, policy, document digests, answers, expiry, and nonce;
2. acquires the required idempotency/subject locks;
3. appends the pending evidence event;
4. yields its receipt to the protected domain action;
5. records the resulting outcome and consumes one-time authorization where applicable;
6. commits both together; and
7. invokes optional notifications/analytics only after commit.

If the event write fails, the protected action rolls back. If the block raises, the event rolls back. Repeating an identical idempotency key returns the original result without running the block twice. A conflicting replay fails with a stable `Clickwrap::ReplayRejected` result.

The block receives a read-only `Clickwrap::PendingReceipt`. Its stable `event_id` can be stored by the domain row, but export/verification methods are unavailable until commit. `capture_and!` returns the finalized `Clickwrap::Receipt`; if the transaction rolls back, the pending object becomes invalid instead of masquerading as committed evidence.

Atomic commit does not give Clickwrap permission to guess what a host method meant. Without a configured outcome snapshot, the receipt says only that the named policy, bound subject, evidence event, and block committed together. `record_protected_outcome_with` can add an exact post-action reference/state/fingerprint; it runs and validates inside the transaction, and a failure rolls the whole operation back.

The transaction contract is documented precisely for ownership, nested transactions, savepoints, deadlock/serialization retries, idempotency, callbacks, and after-commit behavior. Automatic retries occur only when Clickwrap can prove the block is safe to retry; otherwise a stable retryable error returns control to the host. Clickwrap never promises atomicity across two independent systems.

### Capture without a protected action

```ruby
receipt = Clickwrap.capture!(
  :current_terms,
  actor: current_user,
  http_request: request,
  submission: clickwrap_submission
)
```

### Devise and Rails authentication

The installer detects the authentication stack and generates an explicit adapter—not a hidden `after_create` callback.

For Devise, the generated controller reads:

```ruby
class Users::RegistrationsController < Devise::RegistrationsController
  clickwraps_registration_with :signup
end
```

For Rails’ authentication generator, the generated registration command uses:

```ruby
register_with_clickwrap :signup, user: @user do
  @user.save!
end
```

Both integrations ensure account activation and required evidence commit together. Emails, sign-in, redirects, and after-commit side effects occur only after the transaction has succeeded. A failed evidence write never leaves a normal public account silently active.

Signup is modeled honestly as a prospective-actor flow:

1. the GET creates a short-lived, signed registration-flow identifier;
2. the presentation token binds to that flow, the form object type, and any host-selected tenant—not to a fictional persisted or authenticated user;
3. the adapter validates the submitted presentation before account activation;
4. one transaction persists the account, binds its stable actor reference to the evidence, and commits both; and
5. the receipt records `account_registration` attribution and the actual pre-registration authentication state.

Email addresses, passwords, and raw signup fields are not copied into the token. A token from another browser flow, tenant, form object, or already-created account is rejected. Applications that own a custom registration service use the same primitive directly:

```ruby
receipt = Clickwrap.register!(
  :signup,
  prospective_actor: @user,
  http_request: request,
  submission: clickwrap_submission
) do
  @user.save!
end
```

`register!` returns the same receipt type as `capture_and!`; the authentication adapters are thin conveniences over it.

### External providers use an outbox, not pretend-ACID

Stripe, identity services, timestamp providers, and remote signatures cannot share your database transaction. Use a pending authorization and idempotent outbox:

```ruby
authorization = Clickwrap.authorize_external_action!(
  :identity_provider_handoff,
  actor: current_user,
  subject: verification,
  http_request: request,
  submission: clickwrap_submission
)

ProviderHandoffJob.perform_later(
  authorization_id: authorization.id,
  idempotency_key: authorization.idempotency_key
)
```

```ruby
authorization.record_provider_success_and_consume!(provider_receipt)
```

That final method is one idempotent local transaction. Failures and ambiguous timeouts use `record_provider_failure!` and `record_provider_outcome_unknown!`; the reconciliation task can safely resolve them later. A provider timeout never becomes a fictional success or a second debit.

## Ask readable questions everywhere

The actor proxy is the everyday API:

```ruby
user.clickwraps.current_for?(:signup)
user.clickwraps.required_for?(:current_terms)
user.clickwraps.agreed_to?(:terms)
user.clickwraps.acknowledged?(:privacy_notice)
user.clickwraps.consented_to?(:product_updates)
user.clickwraps.declared?(:non_professional_driver, subject: scheme)
user.clickwraps.authorized?(:withdrawal, subject: withdrawal)
```

Every predicate has a structured form when “no” needs an explanation:

```ruby
result = Clickwrap.verify(
  :withdrawal_authorization,
  actor: user,
  subject: withdrawal
)

result.success?              # => false
result.error                 # => :declaration_expired
result.message               # localized human explanation
result.event_id
result.details               # stable machine-readable facts, no surprise PII
```

Stable errors cover wrong actor/tenant/subject, stale policy, unseen document version, missing answer, expiry, withdrawal, predecessor/order, fingerprint mismatch, consumption, replay, and integrity failure.

The convention is consistent: predicates answer booleans, `verify` returns a result, and bang methods raise a typed error carrying that same result. Applications never need to parse an English error message to make an authorization decision.

### Controller gates that always have remediation

```ruby
class BillingController < ApplicationController
  requires_clickwrap :current_terms, only: :show
end
```

The gate redirects HTML/Hotwire users to the mounted policy capture screen and returns them to the original safe destination after completion. API clients receive a structured `clickwrap_required` response with a presentation endpoint.

A required gate must have a remediation route or an explicit host support fallback. Clickwrap refuses to compile a dead-end gate.

Security-sensitive services should still verify at the domain boundary:

```ruby
Clickwrap.require!(
  :withdrawal_authorization,
  actor: user,
  subject: withdrawal
)
```

Controller gates improve flow; service verification protects the action.

## Consent that can actually be withdrawn

Consent is purpose-specific, initially unselected, and separate from Terms or a Privacy Notice acknowledgment:

```ruby
Clickwrap.document :marketing_notice,
  version: "2026-08-15",
  from: Rails.root.join("app/content/legal/marketing.md")

Clickwrap.policy :marketing_preferences do
  consent_to :product_updates,
    document: :marketing_notice,
    optional: true,
    withdrawal_path: "/settings/privacy"

  consent_to :partner_offers,
    document: :marketing_notice,
    optional: true,
    withdrawal_path: "/settings/privacy"

  retain_with :marketing_consent_evidence
end
```

Leaving an optional checkbox unselected creates no consent grant. The capture receipt can show that the option was offered and not granted, but it does not call silence an affirmative refusal. A policy that truly needs a recorded yes/no choice uses explicit unselected controls:

```ruby
consent_to :research_contact,
  choices: { yes: :grant, no: :decline },
  require_an_explicit_choice: true,
  withdrawal_path: "/settings/privacy"
```

```ruby
Clickwrap.withdraw!(
  :product_updates,
  actor: current_user,
  http_request: request,
  because: "The user withdrew this purpose in privacy settings"
)
```

Withdrawal appends an event; it never deletes or mutates the historical grant. The policy’s post-commit hook can stop future processing or enqueue host-owned deletion work without making the original transaction depend on an analytics/job backend.

```ruby
config.after_event_is_committed = lambda do |event|
  Marketing::StopProcessingJob.perform_later(event.actor_id) if event.consent_was_withdrawn?
end
```

Clickwrap structurally requires an accessible withdrawal path. It does not decide whether consent is the correct lawful basis.

## Expiring and corrected declarations

```ruby
Clickwrap.policy :driver_declaration do
  declare :non_professional_driver,
    document: :driver_declaration,
    valid_for: 1.year,
    subject_fingerprint_with: ->(scheme) { scheme.evidence_fingerprint }
end
```

```ruby
user.clickwraps.declared?(:non_professional_driver, subject: scheme)
user.clickwraps.declaration(:non_professional_driver, subject: scheme).expires_at
```

Renewal always starts a new validity period. Correction, supersession, and expiry append linked lifecycle events:

```ruby
Clickwrap.correct_declaration!(
  :non_professional_driver,
  actor: user,
  subject: scheme,
  replaces: old_receipt,
  http_request: request,
  submission: clickwrap_submission
)
```

The host retains domain-specific eligibility and declaration models. Clickwrap owns presentation, evidence, lifecycle, receipts, and verification—not your business rules.

## Narrow, one-time authorizations

```ruby
Clickwrap.policy :withdrawal_authorization do
  acknowledge :withdrawal_requirements

  declare :ride_exclusivity,
    subject_fingerprint_with: ->(withdrawal) { withdrawal.covered_rides_fingerprint }

  authorize :withdrawal,
    one_time: true,
    valid_for: 10.minutes,
    requires: %i[withdrawal_requirements ride_exclusivity],
    record_protected_outcome_with: lambda { |withdrawal|
      {
        action: :submitted,
        reference: withdrawal.to_gid.to_s,
        fingerprint: withdrawal.evidence_fingerprint
      }
    }
end
```

`capture_and!` locks and consumes the authorization in the same transaction as the withdrawal. Another withdrawal, changed ride set, stale declaration, wrong ordering, or concurrent replay cannot reuse it.

This is the core difference between “the user once accepted something” and “this exact evidence authorized this exact operation.”

## Operator attestations

```ruby
Clickwrap.policy :manual_bank_transfer do
  attest :beneficiary_matches_verified_identity
  attest :bank_accepted_transfer
  authorize :record_transfer_as_sent, one_time: true
end
```

Attestations preserve which authorized operator asserted which operational fact, under which role and authentication context, while the host owns permissions and domain state.

## External agreements and imported receipts

When Stripe, DocuSign, Ironclad, or another provider owns the presentation, do not pretend your application captured the click:

```ruby
Clickwrap.import_external_receipt!(
  :connected_account_service_agreement,
  actor: user,
  provider_name: "stripe",
  provider_event_id: account.id,
  provider_receipt: account.service_agreement,
  verified_with: :stripe_api,
  verified_at: Time.current
)
```

The event is labeled `external_receipt`, preserves provider provenance and validation status, and can participate in host verification without becoming a fictional local presentation.

## Receipts answer “show me exactly what happened”

Every event has one canonical JSON receipt and one human-readable HTML projection:

```ruby
receipt = Clickwrap.receipt(event_id)

receipt.to_canonical_json
receipt.to_html
receipt.to_pdf              # your renderer over to_html; never the source of truth
receipt.verify
```

An abbreviated receipt looks like:

```json
{
  "schema": "clickwrap.receipt.v1",
  "event_id": "01K2Y8T5QY0N4V6N1H4G4CQY8J",
  "policy": { "key": "signup", "revision": "sha256:..." },
  "actor": {
    "type": "User",
    "reference": "usr_...",
    "attribution": { "method": "account_registration", "authenticated": false }
  },
  "acts": [
    { "statement": "terms", "kind": "agreement", "action": "agreed" },
    {
      "statement": "privacy_notice",
      "kind": "acknowledgment",
      "action": "acknowledged"
    }
  ],
  "documents": [
    {
      "statement": "terms",
      "key": "terms",
      "version": "2026-08-15",
      "locale": "en",
      "digest": "sha256:..."
    }
  ],
  "presentation": {
    "manifest_digest": "sha256:...",
    "submit_button_text": "Create account",
    "locale": "en",
    "capture_channel": "web_browser",
    "offered_at": "2026-08-15T12:34:56.123456Z",
    "proves": "The server generated this presentation manifest and accepted a submission bound to it. It does not establish that the person read or understood the documents, saw particular pixels, or received a legally sufficient interface."
  },
  "outcome": { "action": "created", "reference": "gid://my-app/User/1" },
  "request_evidence": {
    "ip_address": { "state": "not_configured" },
    "browser_user_agent": { "state": "not_configured" },
    "ip_geolocation": { "state": "not_configured" }
  },
  "integrity": {
    "digest_algorithm": "sha256",
    "event_digest": "sha256:...",
    "receipt_digest": "sha256:...",
    "tier": "baseline",
    "detects": "The recorded digest detects accidental or ordinary modification of the bytes it covers. It does not establish who produced them, when, or that a party controlling both the application and the database could not have written both the record and the digest."
  }
}
```

Two digests, because they answer different questions. `receipt_digest` covers this receipt body, so a verifier holding only the file can check it. `event_digest` was computed over the event's own canonical body when the event was written, and nothing in a standalone file can re-derive it — it is reported so a reader can compare it against the application's own record.

The bundle can include exact document files, manifest, per-act lifecycle/predecessor graph, protected outcome, optional provider receipts, integrity/checkpoint verification, system explanation, and verifier version.

`to_canonical_json` returns the verifiable core receipt and omits raw sensitive request evidence by default. Raw IP address, browser user-agent, and IP-geolocation values live in a separately encrypted evidence annex with its own digest, authorization, retention, hold, and disposition state. That boundary lets the core event remain immutable when a permitted retention process later removes the annex.

Canonical receipts use versioned schemas and the [JSON Canonicalization Scheme (RFC 8785)](https://www.rfc-editor.org/rfc/rfc8785), plus a published Clickwrap profile for UTC timestamps, decimals, identifiers, binary digests, absent values, and extension names. They never depend on Ruby object serialization, YAML, database column order, or the current policy source. Unknown schema versions fail honestly instead of being “best effort” reinterpreted.

### View and download

With the engine mounted:

```ruby
clickwrap_receipt_path(receipt)
```

Actors can view their own receipts. Operator access is always host-authorized:

```ruby
config.authorize_receipt_access_with = lambda do |controller, receipt|
  controller.current_user == receipt.actor || controller.current_user.admin?
end
```

Foreign IDs return not found; existence is not leaked.

### Export only the sensitive fields you intend

```ruby
Clickwrap.export_receipt(
  receipt,
  requested_by: current_operator,
  because: "Investigate dispute 2026-184",
  include_ip_address: false,
  include_browser_user_agent: false,
  include_ip_geolocation: false
)
```

There is intentionally no vague `include_sensitive_context: true` switch. Unredacted operator access and export require host authorization plus a human-readable reason and append an access event. Actor self-service follows the host’s configured disclosure policy without revealing internal fraud/security fields by accident.

### Verify inside or outside the application

```ruby
Clickwrap::Receipt.verify(canonical_json, documents: document_files)
```

```bash
clickwrap verify receipt.json --documents ./receipt-documents
```

The standalone verifier does not need the host application’s source code. At the baseline tier it verifies schema, canonical bytes, digests, links, and bundled content consistency; it does not claim that a self-contained file could not have been fabricated by someone controlling every source. Independent anchors/provider signatures add the stronger origin/time evidence they actually supply. Golden fixtures ensure new releases continue verifying every historical receipt format.

## Optional request evidence, private by default

Clickwrap always records its event ID, server time, capture channel, policy/application version, configured actor/authentication source, and HTTP request ID when available.

It records none of these personal/request-derived fields unless the initializer or policy names them:

- raw IP address;
- raw browser User-Agent;
- IP-geolocation country, region, city, postal code, coordinates, timezone, continent, metro code, or accuracy radius;
- browser/device fingerprints; or
- actual GPS/device location.

Browser fingerprinting and GPS are never collected by the base gem. IP geolocation is provider-estimated network context—not identity, GPS, a street address, or proof that the person was physically there.

Those defaults are evidence design, not fear of useful data. IP addresses and linked online identifiers can be personal data ([Breyer, C-582/14](https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX%3A62014CJ0582)); keeping them on first-party infrastructure does not remove purpose, lawful-basis, transparency, minimization, protection-by-default, security, retention, or high-risk-assessment duties ([GDPR Articles 5](https://eur-lex.europa.eu/eli/reg/2016/679/art_5/oj/eng), [6](https://eur-lex.europa.eu/eli/reg/2016/679/art_6/oj/eng), [13](https://eur-lex.europa.eu/eli/reg/2016/679/art_13/oj/eng), [25](https://eur-lex.europa.eu/eli/reg/2016/679/art_25/oj/eng), [32](https://eur-lex.europa.eu/eli/reg/2016/679/art_32/oj/eng), and [35](https://eur-lex.europa.eu/eli/reg/2016/679/art_35/oj/eng)). Clickwrap therefore supports rich capture while requiring a present, named posture.

MaxMind expressly describes GeoIP as approximate and not capable of identifying a household, individual, or street address; Cloudflare describes its fields as location information for an IP address ([MaxMind accuracy guidance](https://support.maxmind.com/knowledge-base/articles/maxmind-geolocation-accuracy); [Cloudflare IP geolocation](https://developers.cloudflare.com/network/ip-geolocation/)). Clickwrap preserves that uncertainty instead of polishing an estimate into a stronger claim.

### Enable exactly what one policy needs

```ruby
Clickwrap.policy :regulated_authorization do
  authorize :regulated_action, one_time: true, valid_for: 10.minutes

  review_request_evidence_configuration_on Date.new(2027, 8, 15)

  record_ip_address(
    encrypted: true,
    retain_until: :regulated_evidence_retention_ends,
    because: "Investigate account compromise and disputes about this action",
    legal_basis_reference: "LIA-SECURITY-2026-01"
  )

  record_browser_user_agent(
    encrypted: true,
    retain_until: :regulated_evidence_retention_ends,
    because: "Corroborate the client context used for this action",
    legal_basis_reference: "LIA-SECURITY-2026-01"
  )

  record_ip_geolocation(
    country: true,
    region: true,
    city: true,
    postal_code: false,
    latitude_and_longitude: true,
    timezone: true,
    continent: false,
    metro_code: false,
    accuracy_radius_in_kilometers: true,
    using: :trackdown,
    retain_until: :regulated_evidence_retention_ends,
    because: "Corroborate anomalous access and investigate action disputes",
    legal_basis_reference: "LIA-SECURITY-2026-01",
    data_protection_impact_assessment_reference: "DPIA-2026-04"
  )
end
```

Every enabled IP-geolocation result carries provider name/source, estimated state, resolution time, unavailable reason, and any database/accuracy provenance the resolver supplies. A policy cannot keep provider-derived coordinates while stripping the uncertainty needed to interpret them.

Receipts distinguish `not_configured`, `unavailable`, `recorded`, `redacted_for_this_viewer`, `deleted_after_retention`, and `held`. “Blank” is never allowed to blur “we chose not to collect it” into “collection failed.”

The browser cannot submit or replace server-observed values. Clickwrap conventionally reads `request.remote_ip`, and the host must configure/test trusted proxies correctly; Rails documents the forwarding, trusted-proxy, and spoof-check assumptions in [`ActionDispatch::RemoteIp`](https://api.rubyonrails.org/classes/ActionDispatch/RemoteIp.html).

Required request enrichment resolves before the evidence/domain transaction begins and is carried into it as verified input; it is never filled in later by analytics. A policy chooses explicitly whether an unavailable resolver blocks capture or produces an `unavailable` state. Network resolvers are supported, but local databases or already-verified edge metadata avoid holding a domain transaction open around a remote call.

### Trackdown is the optional official resolver

```ruby
bundle add trackdown
```

```ruby
config.ip_geolocation_resolver =
  Clickwrap::IpGeolocation::TrackdownResolver.new
```

`trackdown` remains optional. Clickwrap stores only the fields authorized by the active server policy, never the entire result object. Provider presence is not source trust: Cloudflare-derived fields are marked host-verified only when the application explicitly verifies that requests came through its trusted Cloudflare path.

`footprinted` remains analytics, not authoritative evidence. A sanitized event ID/policy/kind may be emitted to analytics after commit; analytics failure can never undo or substitute for the Clickwrap event.

### Easy installer recipes without a fake compliance switch

The installer can scaffold either starting point:

```bash
bin/rails generate clickwrap:install \
  --request-evidence-recipe=privacy-minimized
```

```bash
bin/rails generate clickwrap:install \
  --request-evidence-recipe=evidence-rich
```

The second recipe asks about every field, purpose, encryption choice, access/export policy, trusted-source posture, and retention rule. It then writes every individual setting into the initializer and disappears. There is no runtime `gdpr_compliant_mode`, `maximum_evidence`, `track_everything`, or `legal_proof` option.

Recipes are scaffolding, never compliance verdicts.

## Retention, deletion, and legal holds are first-class

Every policy chooses an application-defined retention class:

```ruby
Clickwrap.retention :ordinary_agreement_evidence do
  retain_core_event_for 6.years
  delete_recorded_ip_address_after 90.days
  delete_recorded_browser_user_agent_after 90.days
  delete_recorded_ip_geolocation_after 90.days
end
```

Event-based and “later of” rules are supported for regulated records:

```ruby
Clickwrap.retention :regulated_evidence do
  retain_core_event_until :regulated_evidence_retention_ends
  retain_recorded_ip_address_until :security_evidence_retention_ends
  retain_recorded_browser_user_agent_until :security_evidence_retention_ends
  retain_recorded_ip_geolocation_until :security_evidence_retention_ends
end
```

```ruby
config.calculate_retention_time_for :regulated_evidence_retention_ends do |event|
  [
    event.recorded_at_by_server + 5.years,
    event.subject_liquidated_at&.+(3.years)
  ].compact.max
end
```

Clickwrap does not decide those periods. It makes reviewed policies executable and auditable.

Preview every disposition before applying it:

```bash
bin/rails clickwrap:retention:plan
bin/rails clickwrap:retention:apply PLAN=01K2Y8T5QY0N4V6N1H4G4CQY8J
```

The plan is immutable, scoped, expiring, and rechecked at apply time. A newly placed hold, changed policy, changed eligibility, or stale plan stops disposition instead of deleting a broader set than the operator reviewed.

Destructive public methods name exactly what they remove:

```ruby
Clickwrap.delete_recorded_ip_address!(receipt, because: "Retention period ended")
Clickwrap.delete_recorded_browser_user_agent!(receipt, because: "Retention period ended")
Clickwrap.delete_recorded_ip_geolocation!(receipt, because: "Retention period ended")
```

Deletion removes the selected encrypted annex value, appends a disposition event, and changes the current receipt projection to `deleted`; it does not rewrite the historical agreement/declaration/authorization. Verification thereafter proves the immutable core event and its disposition history while reporting that the raw annex value is no longer available. A retained digest is described as a retained linkable digest, never automatically called anonymous.

### Legal holds

```ruby
receipt.place_on_legal_hold!(
  because: "Pending dispute 2026-184",
  placed_by: current_operator,
  review_on: 6.months.from_now
)

receipt.release_legal_hold!(
  because: "Dispute resolved",
  released_by: current_operator
)
```

A hold pauses scheduled disposition, requires a reason/owner/review date, and is itself append-only evidence.

Deleting an actor account never silently cascades evidence. The installer uses restrictive/nullifying relationships plus a stable configured pseudonymous actor reference. Host retention policy decides what remains.

### Privacy inventory and actor requests

Clickwrap can describe what the application configured without pretending that configuration is lawful:

```bash
bin/rails clickwrap:privacy:inventory
bin/rails clickwrap:privacy:export ACTOR=gid://my-app/User/123
bin/rails clickwrap:privacy:disposition:plan ACTOR=gid://my-app/User/123
```

The inventory lists every policy, personal/request-derived field, stated purpose, host-supplied legal-basis reference, provider/source, encryption state, access callback, retention rule, unresolved host event, and review date. The actor export uses the same authorization/redaction rules as receipts. The disposition command only creates a reviewable plan; it does not decide whether an erasure request overrides retention duties, legal claims, or a hold.

Programmatic equivalents return structured results for a host-owned privacy workflow:

```ruby
Clickwrap::Privacy.inventory
Clickwrap::Privacy.export_for(actor, requested_by: current_operator)
Clickwrap::Privacy.plan_disposition_for(
  actor,
  requested_by: current_operator,
  because: "Verified erasure request DSAR-2026-41"
)
```

Correcting an actor’s current email/name or unlinking an account changes the host projection, not the historical snapshot. A host may append a correction/linkage event when needed; Clickwrap never silently edits what an old receipt recorded.

## Progressive, honest integrity

Clickwrap starts useful with an ordinary Rails database and lets serious applications add assurance without changing the capture API.

| Tier | Capability | Honest claim |
|---|---|---|
| Baseline | Canonical receipts, immutable snapshots, versioned SHA-256 digests, append-only public API, independent verifier | Detects accidental/ordinary mutation of the verified bytes |
| Database hardening | Constraints and adapter-specific update/delete protections | Rejects unsupported mutation paths within the documented database threat model |
| Chained history | Per-tenant or per-aggregate event chains/checkpoints | Makes rewriting history detectable when checkpoints remain trustworthy |
| Independent anchoring | Heads stored/published outside the primary database | Improves evidence against a privileged primary-database rewrite |
| Trusted timestamp/provider | RFC 3161 or qualified trust-service receipt adapters | Preserves exactly the assurance and validation status supplied by that provider |

Enable optional hardening explicitly:

```bash
bin/rails generate clickwrap:hardening --database
bin/rails db:migrate
```

```ruby
config.digest_canonical_receipts_with = :sha256
config.chain_event_history_with = :sha256
config.anchor_event_history_with = MyIndependentAnchor.new
config.timestamp_receipts_with = MyRfc3161TimestampProvider.new
```

A local hash is never called tamper-proof. Server-recorded time is never called trusted time. An IP address is never called identity. Provider receipts are never upgraded into guarantees the provider did not make.

Run verification continuously:

```bash
bin/rails clickwrap:verify
bin/rails clickwrap:verify EVENT_ID
```

## Multi-tenancy, actors, subjects, and authority

The conventional actor is `User`, but nothing is hard-coded:

```ruby
Clickwrap.configure do |config|
  config.actor_class_name = "Account"
  config.current_actor_method_name = :current_account

  config.find_current_tenant_with = lambda do |controller|
    controller.current_organization
  end
end
```

Actors, subjects, and tenants are separate:

```ruby
Clickwrap.capture!(
  :logo_rights_declaration,
  actor: current_user,
  subject: @organization,
  tenant: current_organization,
  http_request: request,
  submission: clickwrap_submission
)
```

Actor snapshots include only configured fields. Clickwrap never serializes a whole user or domain object into evidence.

Authentication, actor, organization, and subject are not collapsed into one polymorphic ID. A signed-in employee acting for an organization can be represented explicitly:

```ruby
Clickwrap.capture!(
  :organization_terms,
  actor: current_user,
  acting_for: current_organization,
  subject: contract,
  authentication_context: clickwrap_authentication_context,
  http_request: request,
  submission: clickwrap_submission
)
```

By default, the configured actor must match the authenticated principal. Delegation, guardianship, service-account action, and impersonation are rejected unless the policy and host authority adapter explicitly permit them. When permitted, the receipt preserves the authenticated principal, asserted actor, represented party, authority source, role, and verification time as separate facts; Clickwrap does not decide whether that authority is legally sufficient.

### Anonymous actors

Use a host-owned stable opaque identifier—not an IP address:

```ruby
actor = Clickwrap.anonymous_actor("checkout_#{signed_checkout_id}")
```

The host owns later account linking and identity/capacity decisions.

### System-created records and explicit exemptions

Seeds, imports, administrators, invitations, and service accounts must never “accept” by omitting a browser parameter or by fabricating a human click:

```ruby
Clickwrap.exempt!(
  :signup,
  actor: Clickwrap.system_actor("database_seed"),
  subject: user,
  because: "Generated demo account; no human signup occurred"
)
```

The event is an `exemption`, not an agreement. Policies can permit or reject it explicitly. Every exemption records who/what created it and why.

Exemptions never satisfy `agreed_to?`, `consented_to?`, or another human-action predicate unless a policy asks the separate `exempted_from?` question. There is no “missing checkbox means system account” inference.

## Hotwire, Hotwire Native, APIs, and no-JavaScript flows

The default helper is server-rendered HTML and works with:

- normal full-page requests;
- Turbo Drive and Turbo Frames;
- validation re-renders with no JavaScript;
- Hotwire Native web screens;
- custom native/API presentations; and
- operator/admin surfaces.

No Stimulus controller is required for correctness. An optional tiny controller may improve disabled-submit affordances, but server validation and evidence capture work without it.

### Hotwire Native

Use the web component whenever possible. Legal-document links can open in the appropriate modal/sheet/external-browser context chosen by the host native shell. The same presentation token and receipt contract applies.

Native path configuration remains host-owned. Mount/capture routes include both GET and form-action paths so validation stays in the intended navigation context.

### JSON/API clients

Present a policy through the same server-owned presenter:

```ruby
presentation = Clickwrap.present(
  :signup,
  actor: api_actor,
  locale: :es,
  capture_channel: :native_api,
  submit_button_text: "Crear cuenta"
)

render json: presentation
```

The client renders the declared statements and returns only the signed token plus answers:

```ruby
Clickwrap.capture!(
  :signup,
  actor: api_actor,
  capture_channel: :native_api,
  submission: Clickwrap.submission_from(params),
  client_reported_context: permitted_client_context
)
```

`submission_from` reads only the signed presentation token and the answer keys/types declared by that manifest; unknown keys and malformed choices are rejected. Client-reported values remain explicitly labeled. They can never masquerade as server-observed IP address, server time, trusted identity, or provider-estimated IP geolocation.

## Accessible defaults without a fake certification

The reference helper and views ship with tested:

- explicit labels and programmatic names;
- initially unselected controls;
- visible keyboard focus;
- high-contrast conventional links;
- `aria-invalid` and `aria-describedby` error relationships;
- error summary and focus behavior;
- keyboard operation;
- non-color-only meaning;
- no-JavaScript validation;
- locale-aware document selection; and
- review/correction support for consequential submissions.

The whole host page still determines placement, clutter, contrast, action wording, accessibility, and notice quality. Clickwrap can lint known hazards; it cannot certify a host application as accessible or an agreement as enforceable.

## Operations you can understand at 03:00

```bash
bin/rails clickwrap:doctor
bin/rails clickwrap:publish:plan
bin/rails clickwrap:publish
bin/rails clickwrap:reacceptance:plan POLICY=current_terms
bin/rails clickwrap:verify
bin/rails clickwrap:export EVENT_ID
bin/rails clickwrap:retention:plan
bin/rails clickwrap:retention:apply PLAN=PLAN_ID
bin/rails clickwrap:holds:review
bin/rails clickwrap:privacy:inventory
bin/rails clickwrap:reconcile_external_actions
```

`clickwrap:doctor` reports objective configuration and data facts:

```text
✓ 6 policies compiled
✓ all referenced documents are published and digest-verified
✓ signup has an atomic Devise integration
✓ every required gate has a remediation route
✓ request-derived personal data is off by default
! withdrawal_authorization records IP geolocation city without a review date
! Cloudflare source trust is unverified
✓ no overdue disposition jobs
✓ all checked event digests verify
```

It never prints “compliant,” “court-proof,” or “audit guaranteed.”

Metrics and notifications use stable policy/kind/outcome names without raw personal data labels. Sensitive values never appear in ordinary logs, exceptions, `inspect`, notifications, or metrics.

## Testing is a first-class API

Include the helpers in Minitest:

```ruby
class ActiveSupport::TestCase
  include Clickwrap::TestHelpers
end
```

Create real, internally consistent test evidence without knowing table details:

```ruby
receipt = capture_clickwrap(
  :signup,
  actor: user,
  answers: { terms: true, privacy_notice: true }
)

assert_clickwrap_current :signup, actor: user
assert_clickwrap_agreed_to :terms, actor: user
assert_clickwrap_acknowledged :privacy_notice, actor: user
assert_clickwrap_receipt_verifies receipt
```

System-test helpers drive the actual UI:

```ruby
complete_clickwrap :signup
click_button "Create account"
```

Fault injection proves required atomicity:

```ruby
Clickwrap::Testing.fail_next_event_write do
  assert_raises(Clickwrap::EventWriteFailed) do
    perform_signup
  end
end

assert_not User.exists?(email: "person@example.com")
assert_no_clickwrap_event :signup
```

Concurrency, duplicate-submit, stale-token, actor/subject swap, disposition, legal-hold, export round-trip, and legacy-import helpers ship with the gem. No tests make real provider network calls.

## The generated initializer explains itself

The complete initializer is annotated in plain English. A representative configuration looks like:

```ruby
# config/initializers/clickwrap.rb
Clickwrap.configure do |config|
  config.actor_class_name = "User"
  config.current_actor_method_name = :current_user
  config.parent_controller_class_name = "ApplicationController"

  config.find_current_tenant_with = lambda do |controller|
    controller.current_organization if controller.respond_to?(:current_organization)
  end

  config.authorize_receipt_access_with = lambda do |controller, receipt|
    controller.current_user == receipt.actor
  end

  config.authorize_unredacted_request_evidence_access_with =
    lambda do |controller, receipt, because|
      controller.current_user&.security_operator? && because.present?
  end

  config.identify_actor_with = ->(actor) { actor.to_gid.to_s }
  # Add only reviewed fields your receipts truly need; never serialize the model.
  config.snapshot_actor_with = ->(_actor) { {} }
  config.describe_authentication_with = lambda do |controller|
    { method: :authenticated_session, authenticated_at: controller.session[:authenticated_at] }
  end

  config.store_document_contents_in = :database
  config.digest_canonical_receipts_with = :sha256
  config.chain_event_history_with = nil
  config.anchor_event_history_with = nil
  config.timestamp_receipts_with = nil
  config.application_version = -> { ENV["RELEASE_SHA"] }

  # Safe defaults: no raw network/browser/geolocation data is stored.
  config.record_ip_address_by_default = false
  config.record_browser_user_agent_by_default = false
  config.record_ip_geolocation_country_by_default = false
  config.record_ip_geolocation_region_by_default = false
  config.record_ip_geolocation_city_by_default = false
  config.record_ip_geolocation_postal_code_by_default = false
  config.record_ip_geolocation_latitude_and_longitude_by_default = false
  config.record_ip_geolocation_timezone_by_default = false
  config.record_ip_geolocation_continent_by_default = false
  config.record_ip_geolocation_metro_code_by_default = false
  config.record_ip_geolocation_accuracy_radius_in_kilometers_by_default = false

  # If a default above becomes true, fill in the matching plain-English
  # reason and a retention rule below. The policy compiler rejects an
  # enabled default whose purpose or retention is blank.
  config.reason_for_recording_ip_addresses_by_default = nil
  config.reason_for_recording_browser_user_agents_by_default = nil
  config.reason_for_recording_ip_geolocation_by_default = nil
  config.legal_basis_reference_for_recording_ip_addresses_by_default = nil
  config.legal_basis_reference_for_recording_browser_user_agents_by_default = nil
  config.legal_basis_reference_for_recording_ip_geolocation_by_default = nil
  config.review_default_request_evidence_configuration_on = nil

  config.encrypt_recorded_ip_addresses = true
  config.encrypt_recorded_browser_user_agents = true
  config.encrypt_recorded_ip_geolocation = true

  # Nil means every policy that enables the field must supply its own rule.
  config.delete_recorded_ip_addresses_after = nil
  config.delete_recorded_browser_user_agents_after = nil
  config.delete_recorded_ip_geolocation_after = nil

  config.read_ip_address_from_http_request_with =
    ->(http_request) { http_request.remote_ip }

  config.read_browser_user_agent_from_http_request_with =
    ->(http_request) { http_request.user_agent }

  config.ip_geolocation_resolver = nil
  config.fail_capture_when_ip_geolocation_is_unavailable = false

  # Runs only after required evidence and domain state have committed.
  # Hook failures are reported but can never undo the committed action.
  config.after_event_is_committed = ->(event) { }
  config.report_after_commit_failure_with = ->(error, event) { Rails.error.report(error) }
end
```

Every public setting validates its value and reads like a sentence. Class names are resolved lazily for Rails autoloading. Security-critical ambiguity fails at boot instead of becoming a surprising runtime default. A policy-level request-evidence declaration overrides these application defaults, so a high-risk authorization can collect more context without making ordinary signup inherit it.

## Generators

```bash
bin/rails generate clickwrap:install
bin/rails generate clickwrap:policy driver_declaration
bin/rails generate clickwrap:document terms
bin/rails generate clickwrap:views
bin/rails generate clickwrap:hardening --database
bin/rails generate clickwrap:upgrade
```

The installer:

- detects integer/UUID keys and supported database features;
- detects Rails authentication and Devise without making either a hard dependency;
- stops and explains itself when actor/tenant mappings are ambiguous;
- asks before wiring signup or mounting routes;
- asks separately about every request-evidence field;
- writes plain-English purposes and retention placeholders that must be reviewed;
- never overwrites host files without normal Rails generator conflict handling; and
- prints a post-install checklist for documents, semantics, privacy, retention, trusted proxies, full-page UI review, and tests.

Upgrade generators create new migrations. Released migrations are never silently edited underneath an application.

## Migrate without inventing history

### From FinePrint

Preview first:

```bash
bin/rails clickwrap:import:fine_print:plan
```

Then import:

```bash
bin/rails clickwrap:import:fine_print
```

FinePrint contract versions and signatures become explicit `imported_legacy` events. Fields FinePrint did not record—presentation manifest, IP address, CTA, protected action—remain `unknown` or `not_collected`; Clickwrap never synthesizes them.

### From `accepted_terms_at`

```ruby
Clickwrap.import_legacy!(
  :terms,
  actor: user,
  occurred_at: user.accepted_terms_at,
  known: {
    document_version: user.terms_version
  },
  unknown: %i[
    exact_document_bytes
    presentation
    assertion
    submit_button_text
    request_evidence
  ],
  because: "Imported from users.accepted_terms_at"
)
```

Imports are append-only, provenance-labeled, idempotent, dry-runnable, and report every unknown. Historical weakness remains visible instead of being laundered into modern certainty.

## Extension seams, not dependency soup

The core has small adapter contracts for:

- document storage;
- actor/tenant resolution;
- identity/authentication snapshots;
- IP geolocation;
- independent checkpoints/anchors;
- RFC 3161 or trust-service timestamps;
- external clickwrap/signature providers;
- object-lock/WORM storage;
- PDF rendering;
- authorization;
- error reporting;
- notifications; and
- post-commit analytics/auditing.

Every optional adapter has a no-op default and explicit capability reporting. Installing Clickwrap never pulls in Redis, Sidekiq, Devise, Trackdown, Active Storage, a PDF library, a cloud SDK, or an external service unless the application chooses that integration.

ActiveSupport notifications are available for instrumentation:

```ruby
ActiveSupport::Notifications.subscribe("event_committed.clickwrap") do |event|
  # event payload contains stable IDs and categories, not raw request evidence
end
```

Required writes are never delegated to notifications. Hooks are for observers, not authorization.

## What Clickwrap does, what your application owns, and what the receipt proves

| Area | Clickwrap provides | Your application/counsel owns | Receipt/evidence |
|---|---|---|---|
| Documents | immutable versions, bytes/digests, locales, publication | text, translation, fairness, legal approval, materiality | exact stored version and digest |
| Presentation | tested controls/helper, manifest, token, stale/replay checks | whole-page placement/design, final CTA, accessibility review | server-generated manifest and accepted answers |
| Actor | configured reference and authentication snapshot | identity proofing, capacity, authority, guardian/organization rules | exactly which configured actor/context was recorded |
| Agreements | version/current-state mechanics | enforceability, governing law, substantive terms | agreement event and historical version |
| Privacy notice | acknowledgment mechanics | transparency content and lawful basis for processing | notice version and acknowledgment event |
| Consent | purposes, grant/withdrawal/renewal lifecycle | whether consent is the correct basis and whether it is freely given | exact grant/withdrawal history |
| Declarations | statement snapshot, expiry/correction/supersession | truth, eligibility, domain validation | what was declared, when, for which subject |
| Authorizations | scope, fingerprint, freshness, one-time consumption | domain permission and external-provider consequences | exact evidence-to-outcome binding |
| Request evidence | explicit capture, provenance, encryption/redaction/disposition | necessity, lawful basis, disclosure, trusted proxy/source, period | selected fields and honest source/state |
| Integrity | canonical digests, verification, optional chains/adapters | keys, infrastructure, access controls, backups, operational procedures | verification result and bounded assurance tier |
| Retention | executable rules, holds, dry-run disposition | legally appropriate periods and case-specific holds | retention/hold/disposition history |

Clickwrap is engineering infrastructure, not legal advice or a compliance certificate.

## What Clickwrap deliberately does not become

Clickwrap does not:

- draft or approve your legal documents;
- choose a GDPR lawful basis or special-category condition;
- decide whether a document change is material;
- guarantee enforceability, admissibility, accessibility, or audit acceptance;
- verify identity, age, capacity, guardianship, or organizational authority;
- provide KYC, sanctions screening, fraud scoring, or biometrics;
- become a cookie CMP, tracker scanner, or script blocker;
- become DocuSign, Ironclad, a notary, a qualified trust-service provider, or a contract lifecycle platform;
- call a local hash tamper-proof;
- call an IP address identity or IP geolocation physical location;
- require forced scrolling or claim it proves reading;
- require a sprawling admin/document-authoring suite; or
- hide collection behind `compliant: true` or `maximum_evidence: true`.

Adapters let those systems contribute provider receipts without changing what Clickwrap itself claims.

## What is not finished yet

Everything above is implemented and tested. These parts are deliberately thinner than the rest, and it is better to read that here than to discover it during an audit:

- **Independent anchoring and trusted timestamps are adapter contracts, not providers.** `anchor_event_history_with` and `timestamp_receipts_with` define the interface and ship working no-op defaults. Clickwrap does not bundle an RFC 3161 client or a trust-service integration, and a receipt reports the baseline or chained tier until you supply one.
- **The Active Storage document backend is implemented but lightly exercised.** The database backend is the tested default and the one the whole suite runs against.
- **Database hardening is PostgreSQL-only in substance.** `clickwrap:hardening --database` emits real update/delete protection on PostgreSQL. On SQLite and MySQL it says plainly what the database can and cannot reject rather than generating something that looks like protection and is not.
- **The proof integrations have not run against real applications.** They exist as contract tests in this repository's suite. The four-part release test in [the readiness record](docs/strategy/03-readiness-market-and-next-steps.md) has not been evaluated.
- **No legal or privacy review has been completed** on the default statement wording, the receipt claim sentences, or the request-evidence boundaries.

## FinePrint and Clickwrap solve different-sized problems

[FinePrint](https://github.com/openstax/fine_print/blob/3b75fbcbcfb048ecd2f4ee7c4f0b9bd3d10f7603/README.md#L7-L25) is established Rails prior art for versioned contracts, signatures, gates, and views. Clickwrap should never market itself as the first Rails agreement gem.

FinePrint’s documented core and [signature model at the audited commit](https://github.com/openstax/fine_print/blob/3b75fbcbcfb048ecd2f4ee7c4f0b9bd3d10f7603/app/models/fine_print/signature.rb#L1-L33) answer:

```text
Did user U sign version N of contract X?
```

Clickwrap is for applications that also need to answer:

```text
Which exact content and presentation was offered?
Which explicit statements and choices were made?
Did the required evidence and protected outcome commit together?
What subject or transaction did it cover?
Was it withdrawn, corrected, superseded, expired, or consumed?
Can the complete receipt be reproduced and verified independently?
Can optional personal request evidence be disposed of honestly?
```

The goal is to be easier in the first five minutes and dramatically stronger after five years in production—not FinePrint with more columns.

## Legal and evidentiary posture

Electronic form does not cure an invalid underlying transaction, missing capacity/authority, or a special formality. The US E-SIGN Act preserves electronic validity while retaining substantive requirements and exclusions ([15 U.S.C. § 7001](https://www.law.cornell.edu/uscode/text/15/7001); [15 U.S.C. § 7003](https://www.law.cornell.edu/uscode/text/15/7003)). Electronic form also does not make an unfair term fair ([Directive 93/13/EEC](https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=celex%3A31993L0013)). EU eIDAS distinguishes ordinary electronic evidence from qualified electronic signatures and their specific legal effect ([Regulation (EU) No 910/2014, Article 25](https://eur-lex.europa.eu/eli/reg/2014/910/2024-05-20/eng)).

US appellate formation decisions evaluate conspicuous notice and unambiguous assent in the context of the whole interface; no checkbox color or placement is a universal safe harbor ([Berman v. Freedom Financial Network](https://cdn.ca9.uscourts.gov/datastore/opinions/2022/04/05/20-16900.pdf); [Tejon v. Zeus Networks](https://media.ca11.uscourts.gov/opinions/pub/files/202411114.pdf); [Toth v. Everly Well](https://www.ca1.uscourts.gov/sites/ca1/files/opnfiles/23-1727P-01A.pdf)).

GDPR consent must be demonstrable, distinguishable, and withdrawable, but consent is only one possible lawful basis. A privacy-information acknowledgment is not blanket consent ([GDPR Article 6](https://eur-lex.europa.eu/eli/reg/2016/679/art_6/oj/eng); [GDPR Article 7](https://eur-lex.europa.eu/eli/reg/2016/679/art_7/oj/eng); [AEPD FAQ 02.48](https://www.aepd.es/preguntas-frecuentes/2-tus-obligaciones-como-responsable-del-tratamiento/6-el-deber-de-informacion/FAQ-0248-sobre-si-el-usuario-tiene-que-dar-consentimiento-a-clausula-de-privacidad)). GDPR also requires purpose limitation, data minimization, storage limitation, transparency, and security; “collect everything forever” is not the evidence-maximizing default ([Article 5](https://eur-lex.europa.eu/eli/reg/2016/679/art_5/oj/eng); [Article 13](https://eur-lex.europa.eu/eli/reg/2016/679/art_13/oj/eng); [Article 32](https://eur-lex.europa.eu/eli/reg/2016/679/art_32/oj/eng)).

These sources motivate Clickwrap’s design. They do not turn the gem into legal advice or a universal safe harbor.

## Security model

Clickwrap treats these as hostile until verified:

- policy/document/version/validity values submitted by the client;
- stale or replayed presentation tokens;
- swapped actor, tenant, subject, or transaction IDs;
- forwarded IP and Cloudflare headers outside a verified proxy path;
- client timestamps and client-reported identity/location;
- duplicate/concurrent submits;
- mutable document sources;
- after-commit analytics and provider callbacks; and
- imported evidence without provider provenance.

Security-sensitive values are server-owned, signed/bound, rechecked inside the transaction, and represented by stable failure results. Rails’ CSRF/session/authentication protections remain host responsibilities. Encryption keys, signing keys, and adapter credentials use Rails credentials or application-provided key providers and support rotation with versioned key identifiers.

Report vulnerabilities privately according to `SECURITY.md`. Do not open a public issue containing an exploit or real evidence/PII.

## Compatibility

The ideal supported matrix is:

- Ruby 3.2 through current Ruby, tested explicitly;
- Rails 7.1 through current Rails 8.x;
- PostgreSQL, SQLite, and MySQL for all documented portable core behavior;
- adapter-specific hardening clearly marked and tested;
- Rails authentication and Devise, both optional integrations;
- Turbo/Hotwire and ordinary HTML;
- integer and UUID primary keys;
- multi-database applications when evidence and protected action share the documented transaction boundary; and
- API-only applications for model/service/JSON receipt APIs, with HTML engine mounting optional.

The gem depends only on the Rails components its approved surface needs. It does not depend on the `rails` meta-gem, Redis, a job backend, a JavaScript runtime, an external provider, or a CSS framework.

The actual released gemspec and CI matrix—not this wishlist—are authoritative once implementation exists.

## Stability and upgrade promise

Clickwrap follows semantic versioning for its documented Ruby/Rails APIs, but persisted evidence gets a stricter promise:

- every released receipt schema, canonicalization profile, digest field, event action, and lifecycle meaning has a permanent golden fixture;
- new gem versions continue verifying old receipts even when they stop creating that old schema;
- a format change gets a new explicit schema/version and verifier, never a silent reinterpretation;
- upgrade generators add migrations and report their exact effects; released migration files are never edited under an installed application;
- destructive or lossy data transitions require a plan, explicit operator action, and rollback/export guidance;
- deprecations name the replacement and remain executable for a documented window; and
- security fixes distinguish a vulnerable capture path from a verifier/display-only issue so operators know what historical evidence, if any, needs review.

The project publishes the CI matrix, generator diffs, benchmark script, receipt golden fixtures, threat-model changes, and upgrade notes with every release. “It still boots” is not enough for a gem whose value is long-lived evidence.

## Performance

The ordinary capture path is one bounded database transaction with no network call. Documents and compiled policies are cached by immutable digest. Request geolocation, timestamp providers, external anchors, PDFs, and analytics are optional and never hidden in the simple path.

There is no global event-history mutex. Sequence/chain scope is per tenant or aggregate, benchmarked under contention, and independently checkpointed where enabled. Bulk export streams records and verifies incrementally.

Performance claims are published only with reproducible benchmarks against supported databases.

## FAQ

### Is this an electronic-signature gem?

It captures electronic evidence of explicit actions and can import/provider-bind signature receipts. It does not call ordinary clickwrap a qualified electronic signature, notarization, or trusted identity proof.

### Does a user have to open or scroll through the document?

Not by universal default. Clickwrap makes the document available before action and records the exact presentation. A policy can require an accurately observed open/review interaction when the host has a real requirement, but Clickwrap never equates scrolling with reading or understanding.

### Should I record IP addresses and geolocation?

Only for policies with a present, documented purpose and reviewed access/retention posture. They can corroborate request context but do not repair weak notice or prove identity/physical location. All such fields default off.

### Can I use Clickwrap without Devise?

Yes. Devise and Rails authentication are convenience adapters over the same public capture APIs.

### Can one policy contain several documents and statements?

Yes. The receipt preserves each document/version, statement, choice, and ordering independently. Agreement, acknowledgment, and optional consent controls remain semantically separate even when one page presents them together.

### Can I keep my domain-specific declaration or authorization model?

Yes—and usually should. Clickwrap complements domain models; it does not replace your payout, certification, identity, employment, or eligibility rules.

### Can Clickwrap prove the user saw the page?

It can prove the server generated and accepted a bound presentation manifest and record accurately observed interactions. It cannot prove human attention, comprehension, exact pixels, or legal sufficiency from a database row.

### What happens if Clickwrap is temporarily unavailable?

Required evidence fails closed: the same-database protected action rolls back. Optional after-commit hooks fail independently and are reported. Applications can define deliberate emergency/system exemptions with explicit actor and reason; there is no silent rescue-and-continue path.

### Can I delete evidence?

Yes, according to explicit retention/disposition policy and legal holds. Optional request evidence is separately disposable. Core historical evidence is never silently deleted through an actor association, and disposition is itself recorded.

### Is this GDPR compliant?

No gem can answer that universally. Clickwrap provides privacy-aware mechanisms and truthful defaults. The host remains responsible for lawful basis, necessity, transparency, data-subject rights, security, retention, processors/transfers, DPIAs, and jurisdiction-specific requirements.

## Development

```bash
bin/setup
bundle exec rake test
bundle exec rubocop
```

Against a specific Rails version:

```bash
bundle exec appraisal rails-7.1 rake test
```

Against another database:

```bash
DATABASE_URL=postgres://localhost/clickwrap_test bundle exec rake db:migrate:reset test
```

The project uses Minitest, a dummy Rails application under `test/dummy`, SimpleCov, RuboCop, Appraisal matrices, and SQLite/PostgreSQL/MySQL lanes in CI. The concurrent-writer tests skip on SQLite, which allows a single writer, and run on the PostgreSQL and MySQL lanes where a real race can actually happen.

A few test conventions exist because of what this gem stores:

- the dummy app migrates a **concrete copy** of the install generator's migration template, and a drift test fails the build the moment the two disagree — so "the migration the dummy proved" and "the migration users get" cannot diverge silently;
- fault injection (`Clickwrap::Testing.fail_next_event_write`) proves the atomicity claim from both sides rather than asserting it in prose; and
- every change to canonicalization, receipt schema, digest fields, migrations, or lifecycle meaning must keep verifying every previously released receipt format.

## Contributing

Bug reports and focused pull requests are welcome at https://github.com/rameerez/clickwrap. Please run `bundle exec rake test` and `bundle exec rubocop` first.

Two kinds of change need more than a passing test:

- **Anything touching public vocabulary or an evidence claim** — a method name, a receipt field, a lifecycle meaning, a sentence a receipt prints about what it proves. These need the documentation change alongside the code, plus a note on what happens to receipts already written under the old behavior.
- **Anything touching canonicalization, the receipt schema, digests, or migrations.** Released evidence formats are permanent. A new gem version may stop creating an old schema; it must never stop verifying one.

Please do not use issues to request jurisdiction-specific legal advice or to ask maintainers to approve legal text. Security reports go through [`SECURITY.md`](SECURITY.md), privately, and without real evidence records or personal data in them.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
