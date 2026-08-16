# Integrating clickwrap into a real application

The battle-tested playbook. Everything in this guide was learned by migrating
a production Rails app (Rails 8.1, PostGIS, UUID keys, Devise, Hotwire Native,
Spanish-first, a legacy acceptance ledger, and a wallet-debiting money path)
onto this gem, surface by surface, with the full test suite green after every
step. Follow it in order and you will not rediscover our mistakes.

It is written for humans and for AI agents alike: exact orders of operations,
the boot errors you will meet and what they mean, and the patterns that
survived contact with production code.

## 0. The mental model in five lines

1. **Documents** are frozen bytes with digests. Publishing is explicit.
2. **Policies** are server-owned offers. The browser answers; it never chooses.
3. **Presentations** are signed, short-lived, session-bound tokens. They
   cannot be fabricated — not by attackers, and not by your tests.
4. **Captures** commit evidence and your protected action in one transaction.
5. **Verification** answers questions from the projection, live, with stable
   error symbols and predicates.

## 1. Install, in this exact order

```bash
bundle add clickwrap
bin/rails generate clickwrap:install   # answers adapt to your app; say no to
                                       # every request-evidence question first
bin/rails db:migrate
```

Then, before anything else works:

1. **Point the documents at your REAL legal content**, not the generated
   placeholders. If your legal pages are Markdown with YAML front matter
   (Sitepress-style `app/content/pages/legal/*.html.md`), point `from:` at
   those exact files — the text people accept and the text your `/legal`
   routes serve must be one file, so they cannot drift. Set
   `config.document_renderer = :markdown` and the gem renders through
   whichever Markdown library you already bundle, front matter stripped.
2. **Pick version labels you already own.** If the app has a
   `TERMS_CURRENT_VERSION` constant or a `last_updated` front-matter field,
   use that exact value and keep them in lockstep until legacy columns
   retire. New text = new label; reusing a label for different bytes is
   refused at publish.
3. **Declare a retention class and use it.** `retain_with` is mandatory on
   every policy, on purpose — mark the period `TODO(counsel)` if you must,
   but pick one. If the legacy system kept evidence forever, any finite
   period is a tightening; say so in the comment.
4. `bin/rails clickwrap:publish`, then `bin/rails clickwrap:doctor`. The
   doctor's output is your integration checklist from here on.

If a client needs special navigation attributes, keep the canonical partial
and configure the one narrow seam instead of ejecting it:

```ruby
config.document_link_html_options_with = lambda do |_document|
  { target: "_blank", rel: "noopener", data: { turbo: false } }
end
```

This callback may choose how the client opens the immutable URL. It cannot
return `href:`: the exact href is rendered from, and signed into, the same
presentation manifest.

Boot errors you may meet, all working as intended:

| Error says | It means |
|---|---|
| "presents document X but no declaration exists" | An `acknowledge`/`agree_to` defaults its document to its own key. Point `document:` at a real document — or say `document: nil` for an operational fact whose statement text is the whole notice. |
| "has no retention class" | Add `retain_with`. The gem will not default evidence to forever. |
| "no published version … is effective" | You declared but didn't publish, or the locale doesn't match. Run `clickwrap:publish`; check `locale:`. |
| "unknown option" anything | Options are allowlisted. The error names the valid set — a typo'd option can never silently disable a rule. |

## 2. Test setup — do this before your first integration test

Presentations refuse unpublished documents in tests exactly as in
production, and signed tokens are session-bound so tests cannot mint them by
hand. Both facts produce the same two-part setup:

```ruby
# test/test_helper.rb
class ActiveSupport::TestCase
  include Clickwrap::TestHelpers
  parallelize_setup { Clickwrap.publish! }  # once per parallel worker...
end
Clickwrap.publish!                           # ...and once per process, for
                                             # the runs Rails does not fork
```

Integration tests then read the token off the rendered page, the way a
browser does:

```ruby
post user_registration_path, params: {
  user: { email: "person@example.com", password: "a-real-password" },
  **clickwrap_params_from(new_user_registration_path)   # GET the page, affirm all
}

# Decline one statement instead:
declined = clickwrap_params_from(some_path, answers: { terms: false })

# Radio choices use their exact rendered values. The first rendered choice is
# the default; pass the domain choice when your test depends on it:
contractor = clickwrap_params_from(
  some_path,
  answers: { employment_kind: "contractor" }
)
```

Checkbox statements default to their affirmative value. Radio statements
default to the first choice rendered by the application. This keeps the helper
browser-faithful: it never substitutes the checkbox value `"1"` for an offered
choice such as `"employee"`. Pass an exact choice key when the choice matters.
For conventional `yes`/`no` radio groups, `false` selects `no`.

If a page renders several independent Clickwrap forms, select the exact form.
The helper refuses an ambiguous page rather than mixing one form's signed token
with another form's answers:

```ruby
submission = clickwrap_submission_params_from(
  response,
  form_css_selector: "form[action='/withdrawals/confirm']"
)
```

For service-level tests with no page in the loop, mint the submission
directly: `submission_for(present_clickwrap(:policy, actor:, ...), answers)`.

Two patterns from the trenches:

- **Multi-step funnels**: write a helper that GETs the funnel page, extracts
  whatever presentation is on it, POSTs it to the matching gate, and repeats.
  A funnel parked on a non-gate step simply walks zero gates — exactly like
  the person it simulates. Dispatch on which answer keys the extracted
  params contain.
- **Stubbing around captures**: mint the signed params BEFORE installing
  stubs that count calls — the GET that renders a page may itself trigger
  the code you are counting.

## 3. Signup (Devise or Rails authentication)

```ruby
class Users::RegistrationsController < Devise::RegistrationsController
  clickwraps_registration_with :signup
end
```

The adapter wraps exactly one thing — `resource.save` — so a heavily
customized `create` (bot checks, native handoffs, invitation prefills,
attribution) keeps working untouched. Account and evidence commit together;
refusals (stale token, missing box) re-render the form with localized
sentences, inline beside the control.

**Migrating from a legacy checkbox?** Keep every required legacy evidence write
*inside* the new transaction during the transition:

```ruby
clickwraps_registration_with :signup,
  after_account_is_saved_inside_transaction: :record_legacy_acceptance!

private

def record_legacy_acceptance!(account:, pending_receipt:)
  account.terms_acceptances.create!(
    accepted_at: Time.current,
    clickwrap_event_id: pending_receipt.event_id
  )
end
```

The callback runs after the account save but before the shared transaction can
commit. Do not rescue it: a required legacy-write failure must roll the account
and Clickwrap event back together. Assert the parity contract in one test:
Clickwrap predicates true AND legacy evidence stamped.

**Public forms with no authenticated account** — a lead magnet, newsletter, or
waitlist — must not find an existing actor by the visitor's typed email and bind
evidence to it. Knowing an address is not proof of controlling it. Use a
separate pending-request row, send a single-purpose confirmation link, and only
capture consent for the real actor after that link verifies mailbox control:

```ruby
request = LeadSignupRequest.create!(email: params[:email])
LeadSignupMailer.confirm(request).deliver_later

# After the signed, expiring email link resolves the request:
lead = Lead.find_or_create_by!(email: request.email)
capture_clickwrap!(:marketing_preferences, actor: lead)
```

The initial mail may deliver the requested transactional item. It must not
silently turn the form submit into marketing permission. Model the later box as
`consent_to ..., optional: true`: an unticked box records that the option was
offered and not taken, silence being neither refusal nor grant. Give it a real
`withdrawal_path:` where a signed email-footer token can call
`Clickwrap.withdraw!`; repeated withdrawal remains friendly and distinct from
"never granted".

## 4. Custom surfaces — the three contracts

Anything that is not a plain `form.clickwrap` renders three things that fail
*silently* when hand-typed wrong. The helpers own them; you own every class
and wrapper:

```erb
<% presentation = Clickwrap.present(:withdrawal_preparation, actor: current_user,
                                    submit_button_text: "He leído todo: empezar") %>
<%= clickwrap_presentation_token_field(presentation) %>

<% presentation.statements.each do |statement| %>
  <%= clickwrap_statement_check_box(statement, class: "your-checkbox") %>
  <%= label_tag statement.control_id, statement.assertion %>
<% end %>

<%= clickwrap_submit_button(presentation, class: "your-button") %>
```

`clickwrap_submit_button` is worded by the signed manifest itself — the CTA
is written once, at present time, so the recorded words and the pressed words
cannot drift.

Hard-won rules for custom surfaces:

- **Let the policy own the on-screen words.** Render `statement.assertion` as
  the visible text (a radio card's description, a declaration's body). One
  string on the screen and in the receipt beats two strings and a linter.
- **Radio-shaped answers**: options share the statement's control name;
  affirmative submits `"1"`, negative submits `"0"`
  (`clickwrap_statement_radio_button(statement, "1")` / `"0"`). Any other
  non-empty value reads as affirmative — never use a semantic word like
  `"professional"` as the negative value.
- **Nothing preselected, ever.** A preselected control records the page's
  default, not the person's answer. Preserve selections on re-render only.
- **A dynamic CTA is good evidence**: "Retirar 57,50 €" in the manifest means
  the button they pressed named the amount.
- Your consent-gate JavaScript (disable submit until every box is ticked) is
  welcome as UX; the server refuses partial answers regardless.

## 5. Refusals are one rescue

Everything a *person* can cause from a form — stale token, unparseable
submission, required box left empty — is one family with a message you can
put in front of them:

```ruby
def create
  # ... capture_clickwrap_and! wrapping the protected action ...
rescue Clickwrap::CaptureRefused => refusal
  redirect_to somewhere_path, alert: refusal.user_facing_message, status: :see_other
end
```

Everything outside the family (an evidence write failure above all) stays
loud on purpose. Never rescue `Clickwrap::Error` wholesale: the fail-closed
guarantee is that infrastructure problems refuse the protected action.

## 6. Link domain rows to their evidence

Any row whose existence a capture authorized — a withdrawal, a signed
declaration, a provisioned contract — gets the one-column link:

```bash
bin/rails generate clickwrap:link payouts_withdrawals && bin/rails db:migrate
```

```ruby
class Payouts::Withdrawal < ApplicationRecord
  has_clickwrap_evidence policy: :withdrawal_authorization,
                         statement: :withdrawal,
                         actor: :user,
                         subject: :self
end

capture_clickwrap_and!(:withdrawal_authorization) do |pending_receipt|
  withdrawal.clickwrap_event_id = pending_receipt.event_id
  withdrawal.save!
  withdrawal
end

withdrawal.clickwrap_receipt.verify.success?   # years later, one line
```

## 7. Protecting a money path (the full pattern)

The strongest shape we shipped, for anything where "the user once accepted
something" is not enough and you need "this exact evidence authorized this
exact operation":

- **One policy per gate**, each with its own `valid_for` freshness. A
  multi-step funnel is multiple policies, not one policy squeezed into one
  page.
- **Fingerprint the moving parts**: `subject_fingerprint_with:` recomputes
  from committed rows at capture, so anything that changed between render
  and submit refuses the submit instead of signing over a different state.
- **The final act is `authorize …, one_time: true`,** captured by
  `capture_and!` INSIDE your own locked transaction, wrapping the debit or
  transition itself. `capture_and!` joins an open transaction, so:

  ```ruby
  ActiveRecord::Base.transaction do
    wallet = user.money_wallet.lock!
    # your own rechecks under the lock...
    Clickwrap.capture_and!(:withdrawal_authorization, actor: user, subject: user,
                           http_request: request, submission: submission,
                           authentication_context: { "method" => "password_reauthentication", ... }) do |pending_receipt|
      withdrawal = debit_and_create_row!(pending_receipt.event_id)
      withdrawal # exact result passed to `record_protected_outcome_with`
    end
  end
  ```

  Verification, one-time consumption (by unique index — a conflicting replay
  cannot debit twice), the evidence event, and your debit commit together or
  not at all.
- **Service-boundary checks read aloud**:

  ```ruby
  preparation = Clickwrap.verify(:withdrawal_preparation, actor: user,
                                 require_current_revision: true)
  declaration = Clickwrap.verify(:ride_exclusivity, actor: user, subject: user,
                                 require_current_revision: true)

  declaration.subject_fingerprint_mismatch?   # the ride set changed
  declaration.stale_policy_revision?          # legal reworded it → re-ask
  declaration.recorded_after?(preparation)    # order enforced, not assumed
  ```
- **Non-browser callers fail closed.** Pass `submission: nil` from a job or
  console and capture refuses — which is correct: nothing can mint a
  presentation but a real render. Give operators their own explicit rail.
- **Fresh-password proofs stay yours.** Validate them your way, then record
  them by reference in `authentication_context:` — never the credential.

## 8. Migrating history (do this once, early)

`Clickwrap.import_legacy!` exists so the gem answers for ALL acceptance
history, not just post-migration. The shape that worked:

- **Group legacy rows into acts** (by user + context + accepted-at instant):
  one legacy act becomes one `imported_legacy` event, exactly as a live
  capture would have.
- **`occurred_at` is the old record's time**; the import's own time stays
  separate as `recorded_at_by_server`. The gap between them is itself
  evidence.
- **Name what the source never recorded** in `unknown:` — bytes,
  presentation, button text. Nothing is invented, and the receipt says so.
- **Do NOT copy raw IP/user-agent into `known:`** — that would move personal
  data out of whatever protection it has into the un-encrypted core payload.
  Record a pointer to where they are retained; migrate or delete them with
  your request-evidence retention review.
- Imports are content-addressed idempotent: re-running imports nothing,
  partial runs resume safely. Plan first (`dry_run: true`), always.
- Users with no evidence at all are **counted, never invented** — turning
  them into reviewed `Clickwrap.exempt!` events is its own explicit step.
- Imported evidence satisfies `agreed_to?` / `current_for?` exactly as live
  captures do — a migration must keep answering what the old system
  answered, or it is a mass forced re-acceptance. The receipt stays honest
  about the difference.

## 9. Request evidence, when a surface earns it

Default to collecting nothing; enable per policy, per field, when a surface
has a real purpose (our money path did; our signup did not):

```ruby
policy.record_ip_address(
  encrypted: true,
  delete_after: 2.years,
  because: "Investigate disputes and account takeovers on withdrawals",
  legal_basis_reference: "TODO(counsel): LIA payout evidence"
)
```

Enabling any IP field requires `config.trusted_proxy_configuration_digest` —
a digest of the effective proxy rules, not a prose label, so old evidence
records which configuration was in force. Generate it from Rails' configured
rules (or Rails' actual defaults when none were overridden):

```ruby
config.trusted_proxy_configuration_digest =
  Clickwrap.trusted_proxy_configuration_digest_for_rails_application
```

This records configuration provenance; it does not prove the rules were
correctly deployed or reviewed. Sharing the same fields across several policies?
A plain Ruby lambda in `config/clickwrap.rb` calling
`policy.record_ip_address(...)` is exactly right — each policy still names
its own enablement.

## 10. The rollout doctrine

What let us migrate a live money path with zero downtime and zero weakening:

1. **Dual-write inside the capture transaction.** Legacy evidence rows keep
   being written — from inside `capture_and!`'s block, so both systems
   commit together or neither.
2. **Dual-belt at the boundary, strictest answer wins.** Keep every legacy
   check verbatim and add clickwrap verification on top. Map clickwrap's
   error symbols onto your existing error vocabulary so no UI copy changes.
3. **Only then retire** legacy columns, with the import (§8) already done and
   a parity test standing guard until the day you delete it.

Expect two intentional behavior *sharpenings* when gates become real: blocked
funnels can no longer be blind-POSTed into acknowledged state (no rendered
presentation = nothing to submit), and crafted POSTs outside the right step
bounce to the screen that explains why. Your tests may assert the old, looser
behavior; update them to assert the true one.
