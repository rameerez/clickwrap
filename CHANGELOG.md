# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Changes driven by the first real-host integration (CarHey):

### Changed

- **Imported legacy evidence now satisfies the everyday predicates.**
  `Clickwrap.import_legacy!` projects into current state exactly as a capture
  does, so `agreed_to?`, `acknowledged?`, and `current_for?` keep answering
  what the source system answered — a migration no longer implies mass forced
  re-acceptance. Provenance is unchanged (`imported_legacy` event type,
  `imported_provider` attribution, unknowns named in the receipt), and
  `require_current_version: true` still re-prompts when documents move on.
  0.1.0 was never published, so no installed application observes a behavior
  change.
- The Devise adapter refuses a submission with a missing/stale presentation or
  a declined required statement on the re-rendered form, with the gem's
  localized user-facing sentences (inline beside the control and on `:base`) —
  never a raw exception or a developer-facing message.
- The framework-integration modules (`FormBuilderExtensions`,
  `ControllerHelpers`, `Registration`, `DocumentRenderers::Markdown`) are
  required at boot instead of autoloaded, so hosts whose other gems load
  Action View/Action Controller first no longer fail with an uninitialized
  constant.
- The install migration recognizes the PostGIS adapter as PostgreSQL (jsonb)
  and Trilogy as MySQL; the generated initializer selects the `:safe_text`
  renderer explicitly instead of writing `nil` (which disabled rendering).

### Added

- **View helpers for custom surfaces** (`Clickwrap::ViewHelpers`, available in
  every view): `clickwrap_presentation_token_field`,
  `clickwrap_statement_check_box`, `clickwrap_statement_radio_button`, and
  `clickwrap_submit_button` own the three contracts a hand-written form gets
  wrong silently — the envelope name, the statement control names/ids, and a
  call to action worded by the signed manifest itself. The host owns every
  class and wrapper around them. (Extracted from the CarHey money-path
  migration, where each custom form repeated all three by hand.)
- **`Clickwrap.verify(..., require_current_revision: true)`** — opt-in
  revision currency: evidence recorded under a superseded policy revision
  fails with `:stale_policy_revision` (the verify-time counterpart of the
  capture-time symbol), so "legal reworded the statement → re-ask" is one
  keyword instead of a hand-rolled revision comparison at the host's service
  boundary.
- **Predicates on verification results**, one per stable error symbol and
  generated from the vocabulary so they can never drift:
  `result.no_evidence?`, `result.subject_fingerprint_mismatch?`,
  `result.stale_policy_revision?`, …
- `clickwrap_params_from(path, answers: {})` in TestHelpers — the one-line
  integration-test pattern: GET the page, read the signed token and controls
  back off it, return the POST params.
- The unknown-document boot error now mentions `document: nil` for statements
  about operational facts with no published document.
- `config.document_renderer = :markdown` — real HTML through whichever
  Markdown library the host already bundles (commonmarker, redcarpet, or
  kramdown; no new dependency), with leading YAML front matter stripped from
  the rendered representation only, the engine name and version recorded in
  the receipt, and the same safe-list sanitizer as the reference renderer.
- Spanish locale (`config/locales/es.yml`).
- `clickwrap_submission_params_from(response)` test helper: host integration
  tests read the signed presentation token and its controls back off the
  rendered page, the way a browser does.

## [0.1.0] - 2026-08-15

First implemented release. `clickwrap` turns terms acceptance, privacy notice
acknowledgment, consent, factual declarations, operator attestations, and
one-time authorizations into one Rails primitive: immutable versioned
documents, server-owned policies, signed presentation manifests, append-oriented
evidence events with fixed named disposition transitions, and canonical receipts that can be checked without the
application that wrote them. Required evidence and the protected database
action commit in the same transaction, so an account, payout, or handoff cannot
succeed without the evidence that authorized it. Request evidence — IP address,
browser user-agent, IP geolocation — stays off until a policy names the field,
its purpose, and its retention. The gem provides evidence mechanics only: your
application and its counsel still own the legal text, lawful basis, substantive
validity, capacity, authority, and retention periods.

### Added

- **Immutable versioned documents.** `Clickwrap.document :terms, version:, from:`
  points at the files your application already owns; `bin/rails clickwrap:publish`
  freezes each version into a snapshot with a versioned SHA-256 digest of the
  exact bytes, and `clickwrap:publish:plan` previews what a boot would publish.
  A published version is never rewritten — editing the source file is a new
  version, and receipts keep resolving the bytes they were captured against.
- **Server-owned compiled policies with six honest kinds.** `Clickwrap.policy`
  and its verbal DSL — `agree_to` (agreement), `acknowledge` (acknowledgment),
  `consent_to` (consent), `declare` (declaration), `attest` (attestation),
  `authorize` (authorization) — give each act the lifecycle it actually needs
  instead of calling every checkbox "consent." The policy compiler runs at boot
  and refuses incoherent combinations in a full sentence: an indefinite one-time
  authorization, consent without a withdrawal path, an expiring declaration that
  would have to pretend the original statement was false. The taxonomy is
  product design, not statutory vocabulary; the host picks the kind.
- **Signed presentation manifests.** Every rendered policy carries a signed,
  short-lived manifest of exactly what the server generated and offered: policy key and
  revision, document versions and digests, assertion and link text, choices,
  submit-button text, and locale. Submission is validated against that manifest
  and rechecked server-side, so render-to-submit substitution — a different
  version, a different call to action, a checkbox the server never required —
  is rejected rather than recorded. The browser may answer a policy; it can
  never choose the policy, the version, the validity window, the subject, the
  retention class, or a request-evidence field.
- **`capture!`, `capture_and!`, and `register!` with same-transaction atomicity.**
  `capture_and!` yields a read-only `Clickwrap::PendingReceipt` whose stable
  `event_id` the domain row can store, and commits the evidence and the
  protected action together or not at all; if the transaction rolls back the
  pending object becomes invalid instead of masquerading as committed evidence.
  `capture!` records evidence on its own, and `register!` binds a prospective
  actor to the presentation that preceded the account — the Rails-authentication
  and Devise adapters are thin conveniences over it. Optional
  `after_event_is_committed` hooks are error-isolated and can never undo a
  committed action or stand in for one.
- **Lifecycles that stay truthful over time.** Consent can actually be
  withdrawn, renewed, and scope-changed; declarations expire, get corrected, and
  get superseded without rewriting what was originally stated; one-time
  authorizations are locked and consumed inside the same transaction as the
  action they authorize, so a stale token, a changed subject, a wrong ordering,
  or a concurrent replay cannot reuse one. Every ordinary lifecycle transition
  appends an event with its own predecessor link; reviewed retention uses the
  separately named, fixed disposition transition rather than masquerading as an
  ordinary append.
- **Canonical receipts and a standalone verifier.** Receipts use versioned
  schemas serialized with the [JSON Canonicalization Scheme (RFC 8785)](https://www.rfc-editor.org/rfc/rfc8785)
  plus a published Clickwrap profile for UTC timestamps, decimals, identifiers,
  binary digests, absent values, and extension names — never Ruby object
  serialization, YAML, or database column order. `bin/rails clickwrap:verify`
  and `clickwrap:export` produce and check bundles without the host
  application's source code, and golden fixtures pin every released format so
  new versions keep verifying old receipts. An unknown schema version fails
  honestly instead of being reinterpreted. The baseline tier verifies schema,
  canonical bytes, digests, links, and bundled content consistency, and says so
  precisely; it claims nothing about origin or time that it cannot show.
- **Optional request evidence, off by default and encrypted.** IP address,
  browser user-agent, and each individual IP-geolocation field are collected
  only when a policy names them with a plain-English purpose and a retention
  decision. They live in a separate `ActiveRecord::Encryption` annex, are read
  through their own authorization callback, and are separately disposable
  without touching the core event. There is no `gdpr_compliant_mode`,
  `full_evidence`, or `legal_proof` switch that turns on a category of personal
  data as a side effect of something else — the installer's recipes write every
  individual setting into the initializer and then disappear.
- **Retention classes, legal holds, and dry-run disposition.**
  `Clickwrap.retention` expresses per-field retention (including event-based and
  "later of" rules) as executable, auditable policy. `clickwrap:retention:plan`
  produces an immutable, scoped, expiring plan that `clickwrap:retention:apply`
  rechecks before touching anything, so a newly placed hold or a changed policy
  stops disposition instead of deleting more than the operator reviewed.
  `place_on_legal_hold!` / `release_legal_hold!` require a reason, an owner, and
  a review date; placing and releasing a hold append corresponding evidence
  events while the hold row remains an explicit current-state record. Destructive methods
  name exactly what they remove (`delete_recorded_ip_address!`,
  `delete_recorded_browser_user_agent!`, `delete_recorded_ip_geolocation!`) and
  append a disposition event rather than rewriting history. Clickwrap does not
  decide retention periods; it makes reviewed ones executable.
- **Generators for every step.** `clickwrap:install` detects integer versus UUID
  keys, the database adapter, and Rails authentication versus Devise; it stops
  and explains itself when the actor or tenant mapping is ambiguous, asks
  separately about every request-evidence field, and prints a post-install
  checklist. `clickwrap:policy`, `clickwrap:document`, `clickwrap:views`,
  `clickwrap:hardening --database`, and `clickwrap:upgrade` cover the rest.
  Upgrade generators always create new migrations; a released migration is never
  silently edited underneath an installed application.
- **Importers that do not invent history.** `clickwrap:import:fine_print:plan` /
  `clickwrap:import:fine_print` turn FinePrint contract versions and signatures
  into explicit `imported_legacy` events, and `Clickwrap.import_legacy!` does the
  same for an `accepted_terms_at` column. Fields the legacy source never
  recorded — presentation manifest, IP address, call to action, protected
  action — stay `unknown` or `not_collected`. Clickwrap never synthesizes
  evidence it does not have.
- **A form-builder helper and ejectable reference views.**
  `form.clickwrap :signup, submit: "Create account"` renders the initially
  unselected controls and the bound submit button as one presentation, so the
  call to action in the signed manifest is the one the user can actually press.
  `rails generate clickwrap:views` ejects the reference views — including the
  standalone remediation screen — for hosts that want their own markup.

## [0.0.0]

- Name-reservation release. No implementation: no engine, no models, no
  migrations, no public API, no runtime dependencies. The README describes the
  gem we intend to build, not code that exists today.
