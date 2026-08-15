# Consent, kinds, and lifecycle

Not every checkbox is consent, and not every timestamp is a signature. Clickwrap gives each act
the lifecycle it actually needs, which is why there are six verbs rather than one
`accept` method with options.

**This taxonomy is product design, not statutory vocabulary.** Naming an act `agreement` or
`consent` does not determine its legal effect anywhere. The verb decides which lifecycle
Clickwrap enforces and what the receipt says; your application and its counsel decide whether
that is the right characterization, what the words mean, and what basis the processing rests
on. Choosing between the verbs is the one piece of thinking this gem deliberately does not do
for you.

---

## The six kinds

| Verb | Kind | Means | First action | Every action it can ever record |
|---|---|---|---|---|
| `agree_to` | `agreement` | Assent to contractual terms | `agreed` | `agreed`, `superseded` |
| `acknowledge` | `acknowledgment` | Affirmative receipt or awareness of a notice or risk | `acknowledged` | `acknowledged`, `superseded`, `expired` |
| `consent_to` | `consent` | Purpose-specific permission, where the host has decided consent is the right basis | `granted` | `granted`, `declined`, `withdrawn`, `renewed`, `scope_changed` |
| `declare` | `declaration` | A factual statement made by the actor | `declared` | `declared`, `corrected`, `superseded`, `expired` |
| `attest` | `attestation` | An operational fact affirmed by an authorized actor, usually an operator | `attested` | `attested`, `corrected`, `superseded` |
| `authorize` | `authorization` | Narrow permission bound to one protected action | `authorized` | `authorized`, `consumed`, `expired`, `revoked` |

The action lists are not suggestions. `EventStatement` validates that an action belongs to its
kind and refuses the row otherwise, with a message naming what that kind can record. An
agreement cannot be `withdrawn`; a declaration cannot be `consumed`.

### Which capability each kind has, and why

| Capability | Kinds that have it | Why the others do not |
|---|---|---|
| **Withdrawable** | `consent` only | Withdrawing future consent must never rewrite a historical agreement or a factual declaration. Those are statements about what happened; only a permission can be taken back |
| **Expirable** (`valid_for:`) | `acknowledgment`, `consent`, `declaration`, `authorization` | An agreement does not lapse on a timer — it is superseded by a new version. An attestation is an operational fact that stays true about the moment it described |
| **Correctable** (`correct_declaration!`) | `declaration`, `attestation` | A correction says the fact is different now, not that the original statement was false when it was made. Only statements of fact have that shape |
| **One-time** (`one_time: true`) | `authorization` only | Scoping to a single protected action is what makes an authorization an authorization |

The policy compiler rejects incoherent combinations at boot rather than at 3am: a one-time
authorization that is also indefinite, a consent with no withdrawal path, a subject-bound
statement with no subject fingerprint, a request-evidence field with no purpose or retention
decision.

---

## States and how they change

Current state is a **projection**. Everything in `clickwrap_statement_states` is derived from
`clickwrap_events`; drop the table and `CurrentState.rebuild_for!(actor_reference:)` rebuilds
it. Keeping the projection strictly downstream of the events is what lets it be mutable and
fast without any of that leaking into the record of what actually happened.

| State | Satisfies a requirement | How a statement gets there |
|---|---|---|
| `active` | Yes | A `capture`, `renewal`, or `scope_change` event recorded the initial action |
| `declined` | No | The person answered no to a statement with explicit `choices:` |
| `withdrawn` | No | `Clickwrap.withdraw!` appended a `withdrawal` event |
| `expired` | No | The validity period ran out. Evaluated live against the clock, so verification does not depend on a job having run |
| `superseded` | No | A newer act for the same identity replaced it, or `Clickwrap.supersede!` appended a `supersession` event |
| `consumed` | No | A one-time authorization was used by the transaction it authorized |
| `revoked` | No | `Clickwrap.revoke!` appended a `revocation` event |
| `corrected` | No | `Clickwrap.correct_declaration!` appended a `correction` event; the correction becomes the active statement |
| `exempted` | Only `exempted_from?` | `Clickwrap.exempt!` recorded that no human acted |

### The transition table

| From | Event type | Action recorded | To | What is preserved |
|---|---|---|---|---|
| — | `capture` | the kind's initial action | `active` | Everything: the exact assertion, documents, manifest, answers |
| `active` | `capture` (newer act, same identity) | the kind's initial action | previous becomes `superseded` | The earlier event, untouched. The projection moves on; the event does not |
| `active` | `withdrawal` | `withdrawn` | `withdrawn` | The original grant. Withdrawal appends; it never deletes or mutates |
| `active` | `renewal` | `renewed` | `active`, with a **fresh** validity period | The old expiry does not quietly survive: `effective_at` moves, `withdrawn_at` clears, `expires_at` is recomputed |
| `active` | `scope_change` | `scope_changed` | `active` | The previous scope, as its own event |
| `active` | `correction` | `corrected` | `corrected`, and the correction is `active` | The original statement, which was not false when it was made |
| `active` | `supersession` | `superseded` | `superseded` | Everything the superseded act recorded |
| `active` | `consumption` | `consumed` | `consumed` | The binding between this evidence and the exact transaction it authorized |
| `active` | `revocation` | `revoked` | `revoked` | The original authorization |
| `active` | (validity elapses) | `expired` | `expired` | The original act. Expiry does not imply the statement was ever untrue |
| — | `exemption` | the kind's initial action | `exempted` | Who or what created it, and why. Never satisfies a human-action predicate |

Only four event types count as a human action recorded through a Clickwrap presentation:
`capture`, `correction`, `renewal`, `scope_change`. Only those can satisfy `agreed_to?`,
`consented_to?`, `declared?`, and the rest. An `exemption`, an `imported_legacy` event, or an
`external_receipt` never does — there is no "missing checkbox means system account" inference
anywhere in this gem.

The remaining event types record things that happened *to* evidence rather than acts by a
person: `disposition`, `legal_hold_placed`, `legal_hold_released`, `receipt_access`,
`provider_outcome`.

---

## Consent specifically

Consent is the only withdrawable kind, and Clickwrap structurally requires an accessible
withdrawal path before it will compile a consent policy. It does not decide whether consent is
the correct basis for your processing.

```ruby
Clickwrap.policy :marketing_preferences do
  consent_to :product_updates,
    document: :marketing_notice,
    statement: "I agree to receive product update emails.",
    optional: true,
    withdrawal_path: "/settings/privacy"

  consent_to :partner_offers,
    document: :marketing_notice,
    statement: "I agree to receive offers from selected partners.",
    optional: true,
    withdrawal_path: "/settings/privacy"

  retain_with :marketing_consent_evidence
end
```

Two separate purposes, two separate controls, two separate lifecycles. Bundling them into one
sentence produces a consent record whose meaning nobody can reconstruct later — the development
linter flags exactly that as `consent_statement_bundles_purposes` when it sees "and", "and/or",
"as well as", or "plus" in a consent assertion.

**An unselected optional control creates no grant.** The receipt can show the option was offered
and not taken, but it does not call silence an affirmative refusal — those are different facts
and only one of them happened. When you actually need a recorded decision rather than the
absence of one, ask for it explicitly:

```ruby
consent_to :research_contact,
  choices: { yes: :grant, no: :decline },
  require_an_explicit_choice: true,
  withdrawal_path: "/settings/privacy"
```

Both controls start unselected, and the answer becomes `granted` or `declined` — a real
recorded decision either way.

Withdrawal appends:

```ruby
Clickwrap.withdraw!(
  :product_updates,
  actor: current_user,
  http_request: request,
  because: "The user withdrew this purpose in privacy settings"
)
```

Stopping the downstream processing is your job, and it happens after the transaction commits so
that the record of the withdrawal never depends on a job backend being up:

```ruby
config.after_event_is_committed = lambda do |event|
  if event.event_type == "withdrawal"
    Marketing::StopProcessingJob.perform_later(event.actor_reference)
  end
end
```

The hook is an observer, never authorization. A failure here is reported through
`report_after_commit_failure_with` and swallowed, because the withdrawal event has already
committed and nothing a job backend does may undo it.

---

## Choosing a verb: Terms, privacy notice, marketing

This is the case that could plausibly be any of the three, and getting it wrong is the most
common way an evidence record ends up saying something that did not happen. One signup page,
three different acts:

```ruby
Clickwrap.policy :signup do
  agree_to :terms
  acknowledge :privacy_notice
  consent_to :product_updates,
    document: :marketing_notice,
    optional: true,
    withdrawal_path: "/settings/privacy"

  retain_with :ordinary_agreement_evidence
end
```

**Terms of service → `agree_to`.** The Terms are a contract you are asking the person to be
bound by. The act is assent. It does not expire on a timer; it is superseded when a new version
publishes and you decide the change is material enough to require reacceptance. It is not
withdrawable — you do not "withdraw" from terms, you stop using the service or the contract
ends.

**Privacy notice → `acknowledge`.** A privacy notice is information the person is *entitled to*
under transparency duties ([GDPR Article 13](https://eur-lex.europa.eu/eli/reg/2016/679/art_13/oj/eng))
*(law)*. It is not something they agree to, and it is not permission for anything. Recording it
as an agreement would claim they assented to processing; recording it as consent would be
worse, because it would claim they granted a basis they were never asked for.

The Spanish supervisory authority puts the distinction plainly: a checkbox may serve to prove
that the privacy information was provided, while purposes that genuinely rest on consent should
be collected separately
([AEPD FAQ 02.48](https://www.aepd.es/preguntas-frecuentes/2-tus-obligaciones-como-responsable-del-tratamiento/6-el-deber-de-informacion/FAQ-0248-sobre-si-el-usuario-tiene-que-dar-consentimiento-a-clausula-de-privacidad))
*(regulator guidance)*. `acknowledge` is the verb that records the first thing without claiming
the second.

**Marketing email → `consent_to`, optional, with a withdrawal path.** This is a specific
purpose, separable from the service, and it is the one thing on the page that is genuinely a
permission. It is optional, so leaving it alone grants nothing. It is withdrawable, and the
withdrawal path is required at compile time rather than promised in a policy document.

Consent is one lawful basis among several, and where it is used, GDPR requires it to be
demonstrable, distinguishable from other matters, and withdrawable
([Article 6](https://eur-lex.europa.eu/eli/reg/2016/679/art_6/oj/eng),
[Article 7](https://eur-lex.europa.eu/eli/reg/2016/679/art_7/oj/eng)) *(law)*. Clickwrap gives
you the mechanics for all three. It does not choose the basis, and no verb here should be read
as advice that you have chosen correctly.

### A quick way to decide

Ask, in order:

1. **Is this a permission the person can take back without ending the relationship?** If yes,
   `consent_to`, with a real withdrawal path. If withdrawing it would just mean cancelling the
   account, it is not consent.
2. **Is this information they are entitled to receive, rather than something they grant?** If
   yes, `acknowledge`.
3. **Is this assent to terms that bind them?** If yes, `agree_to`.
4. **Is it a statement of fact about themselves or the world?** `declare` if the person is
   asserting it, `attest` if an authorized operator is.
5. **Is it permission for one specific, consequential operation?** `authorize`, with
   `one_time: true` and a validity window.

If a single control would need two of these answers, it is two controls.

---

## Reading current state

```ruby
user.clickwraps.current_for?(:signup)
user.clickwraps.required_for?(:current_terms)
user.clickwraps.agreed_to?(:terms)
user.clickwraps.acknowledged?(:privacy_notice)
user.clickwraps.consented_to?(:product_updates)
user.clickwraps.declared?(:non_professional_driver, subject: scheme)
user.clickwraps.attested?(:bank_accepted_transfer)
user.clickwraps.authorized?(:withdrawal, subject: withdrawal)
user.clickwraps.exempted_from?(:signup)
```

Every predicate has a structured form for when "no" needs an explanation:

```ruby
result = Clickwrap.verify(:withdrawal_authorization, actor: user, subject: withdrawal)

result.success?   # => false
result.error      # => :declaration_expired
result.message    # localized human explanation
result.event_id
result.details    # stable machine-readable facts, no surprise personal data
```

The convention is consistent: predicates answer booleans, `verify` returns a result, and bang
methods (`Clickwrap.require!`) raise a typed error carrying that same result. Applications never
need to parse an English message to make an authorization decision. The failure symbols are a
fixed vocabulary — `declaration_expired`, `consent_withdrawn`, `authorization_consumed`,
`superseded`, `wrong_subject`, `subject_fingerprint_mismatch`, `replay_rejected`, and the rest —
and like every other stable string in the gem, that list is added to, never renamed or
repurposed.

---

## Sources

| Source | Class |
|---|---|
| [GDPR Article 6](https://eur-lex.europa.eu/eli/reg/2016/679/art_6/oj/eng) — lawful bases | Law |
| [GDPR Article 7](https://eur-lex.europa.eu/eli/reg/2016/679/art_7/oj/eng) — conditions for consent | Law |
| [GDPR Article 13](https://eur-lex.europa.eu/eli/reg/2016/679/art_13/oj/eng) — information to be provided | Law |
| [AEPD FAQ 02.48](https://www.aepd.es/preguntas-frecuentes/2-tus-obligaciones-como-responsable-del-tratamiento/6-el-deber-de-informacion/FAQ-0248-sobre-si-el-usuario-tiene-que-dar-consentimiento-a-clausula-de-privacidad) — a privacy-information checkbox is not blanket consent | Regulator guidance |
| [Directive 93/13/EEC](https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=celex%3A31993L0013) — electronic form does not make an unfair term fair | Law |
| [15 U.S.C. § 7001](https://www.law.cornell.edu/uscode/text/15/7001), [§ 7003](https://www.law.cornell.edu/uscode/text/15/7003) — electronic validity preserved, substantive requirements and exclusions retained | Law |
| `lib/clickwrap/vocabulary.rb`, `lib/clickwrap/dsl/policy_builder.rb`, `lib/clickwrap/statement.rb`, `lib/clickwrap/current_state.rb`, `lib/clickwrap/models/event_statement.rb` at commit `d245b92` | Pinned source code |
| The six-kind taxonomy, the capability matrix, and the decision order above | Product-design inference |
