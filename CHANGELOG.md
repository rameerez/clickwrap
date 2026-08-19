# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.1] - 2026-08-19

### Added — request evidence can keep pace with the evidence it corroborates

- **`keep_recorded_{ip_addresses,browser_user_agents,ip_geolocation}_indefinitely!(because:)`.**
  By-default request evidence used to demand a deletion clock, which — after
  0.2.0 flipped core evidence to keep-indefinitely — scheduled the
  corroboration (IP, user agent, geolocation) to expire before the agreement
  it corroborates. The third option now exists and must be said out loud with
  a reason, like every escape hatch here. Declaring both a clock and
  keep-indefinitely is refused as opposite decisions.

### Documentation

- The request-evidence README section now argues FOR recording: IP + user
  agent + geolocation are what cement a recorded act to a person when the
  dispute is "that wasn't me", and the recommended posture is on-by-default
  with the purpose written down. The discipline is unchanged — no silent
  enablement, per-field decisions, encryption, reviewed proxy provenance.

## [0.2.0] - 2026-08-19

### Changed — evidence is kept indefinitely by default

- **The default retention posture is now indefinite.** A policy that never
  says `retain_with` runs under a new built-in retention class,
  `evidence_kept_indefinitely`: no deletion clock on the core event, none on
  any request evidence. Previously such a policy refused to boot. The
  direction is deliberate: keeping is reversible — a reviewed disposition can
  always run later — while deletion is not, and the day contractual evidence
  matters is usually years past every convenient schedule. Deletion is the
  explicit, reviewed opt-in it always was: declare a class with clocks and
  name it on the policy.
- **A retention class may keep the core event forever.** New DSL verb
  `retain_core_event_indefinitely` says the default out loud; omitting the
  core-event rule now means the same thing instead of raising. Snapshots
  record `{"indefinite" => true}`, the privacy inventory reports
  `{"kind" => "indefinite"}`, events under such a class freeze no deadline,
  and the retention planner never lists them as due — on any horizon.
- **Registries can carry built-in seeds.** `Registry#clear` (every reload)
  now returns a seeded registry to its built-ins instead of to nothing, which
  is what keeps the default retention class alive across `to_prepare`.

### Documentation

- The README installs from rubygems.org (`gem "clickwrap"`), documents the
  new retention default, and shows HTML pages and runtime `resolver:` sources
  for legal documents alongside Markdown.

## [0.1.1] - 2026-08-19

### Fixed — the composed sentence in a language that declines its articles

- **Per-key sentence fragments.** Spanish cannot say "acepto %{documents}" for
  every document — the article agrees with the noun ("los Términos", "la
  Política"). The composer now looks up
  `clickwrap.sentence.fragments.<kind>.<key>` before falling back to the
  per-kind template, and the gem ships Spanish defaults for its standard keys.
  An application adds its own in its locale files; no DSL change.
- **One opening capital.** Fragment templates are written lowercase for the
  middle of a sentence; the composer capitalizes exactly one letter — the
  first — once, at build time, so the signed manifest and the rendered HTML
  can never disagree. The Spanish signup now reads
  "Acepto los Términos y Condiciones y doy por recibida la Política de
  Privacidad." instead of "Acepto Términos y Condiciones y He recibido
  Política de Privacidad."
- **One voice, composed or itemized.** The Spanish composed acknowledgment now
  says "doy por recibida" — the same words as the itemized default statement —
  instead of the flatter "he recibido". The same act reads the same way in
  either rendering. (Still never "he leído": the evidence records an
  affirmative act on an offered notice, not that anyone read it. A host that
  wants the first-person read-declaration owns that wording via its locale
  files — see the next fix.)
- **Host locale overrides actually win now.** The engine appended its locale
  files to `app.config.i18n.load_path` on top of Rails's automatic engine
  locale loading. Railties paths are unshifted ahead of that list, so the
  appended copy landed AFTER the host's own locale files — and every host
  override of a gem key silently lost to the gem's default. The manual append
  is gone; Rails::Engine's own `:add_locales` ordering (gem first, host last)
  is the contract, and a test now pins it.
- **Checkbox optical alignment.** The box was mathematically centred on the
  first line and still read as floating high: Latin text carries its mass
  between cap-height and baseline, below the line box's midpoint. The offset
  gains an optical eighth of an em, calibrated against rendered screenshots.

## [0.1.0] - 2026-08-19

### Changed — the signup clickwrap is one line

- **`form.clickwrap` renders ONE checkbox carrying ONE sentence** whenever every
  statement in a policy is an ordinary, required, default-worded `agree_to` or
  `acknowledge`:

      ☐ I agree to the Terms of Service and I acknowledge the Privacy Policy.

  The documents are linked inside the sentence, and the label IS the sentence —
  pressing the words toggles the control and assistive technology announces both
  together. Gone from the rendering: the "Required" flag, the visible "(opens in
  a new tab)" hint, the version label under each link, and the list of documents
  under each statement. The `required` attribute stays as progressive
  enhancement (THE SERVER DECIDES is unchanged), the new-tab truth is now an
  `sr-only` span rendered only when the link really does open one, and versions
  stay on receipts, where somebody reading the record can act on them.

  The evidence is unchanged. One control, several statements: the manifest signs
  which statement keys it covers and which key it is submitted under, and the
  server fans that one answer out to all of them — each recorded with its own
  kind, documents, assertion, and lifecycle, exactly as before. An unticked or
  absent control refuses every one of them. Whether one answer may cover several
  statements is re-checked at capture against the FROZEN POLICY REVISION, not
  taken on the token's word.

  Nothing that a person could reasonably want to answer differently is folded
  in: optional consents, recorded yes/nos, statements with a withdrawal route,
  and copy an application wrote itself all keep a control of their own below the
  line. A policy with nothing composable — operator attestation rails, payout
  authorizations — renders exactly as it did before. `combined: false` on
  `form.clickwrap` / `form.clickwrap_fields` asks for the itemized shape, and it
  reaches the presenter rather than the template, so the manifest signs the
  shape that was offered. An itemized manifest is byte-identical to the ones
  earlier versions wrote.

  The words are translations: `clickwrap.sentence.agreement`,
  `clickwrap.sentence.acknowledgment`, and three connectives, with `%{documents}`
  marking where the links go. A locale that has not translated them renders the
  itemized shape rather than half an English sentence.

  Custom surfaces iterate `presentation.itemized_statements` rather than
  `statements`, and render `clickwrap_combined_sentence(presentation.combined)`
  when there is one. The presentation linter keeps its preselected-control and
  action-ordering rules and gains
  `combined_statement_rendered_as_its_own_control`, which is where an ejected
  view lands after this change.

- **Receipts record the sentence that was read.** `presentation` gained
  `combined_sentence` and `combined_statements`, shown on the HTML receipt and
  the engine's receipt screen. The acts say what was recorded; this says what
  was on the screen. Both are absent — not null — on an itemized presentation,
  so every receipt written before this change verifies byte for byte exactly as
  it did.

### Added — `link:`, the page a person actually reads a document on

- **`Clickwrap.document :terms, from: ..., link: "/legal/terms"`** presents and
  signs the host's own formatted page instead of the engine's rendering of the
  published bytes. It is the path rendered AND the path signed, so evidence
  never cites a different target from the link somebody pressed, and the trade
  is written where a reviewer sees it: a host page shows whatever is current, so
  the signed path is a stable address rather than an immutable snapshot. The
  bytes stay frozen, digested, and recorded either way.

  Precedence: a resolver passed at the call site, then `link:`, then the render
  context's default resolver (the mounted engine route, with this request's
  Hotwire Native treatment attached — which therefore applies to `link:` paths
  unchanged), then the engine's own routes. The refusal to sign a link an
  unmounted engine cannot resolve is about the ENGINE route, so a policy whose
  every document names a host page now presents with no mount at all, and the
  refusal keeps firing for every document that does not.

  A `link:` is checked at boot for a scheme a browser can navigate:
  `javascript:`, `data:`, a bare word, and protocol-relative `//host` are
  refused with the sentence that fixes them.

- The presenter's framework wiring moved from `document_version_path_with:` to
  `default_document_version_path_with:`, leaving the former as what it always
  read like — the host's own resolver, which still wins outright.
  `clickwrap_document_version_path_for_presentation` gained a `declared_link:`
  keyword.

### Added — the quickstart runs in CI

- **The README quickstart is now executed end to end**, in a subprocess, against
  a throwaway application built only from what the installer emitted: install →
  migrate → declare → `has_clickwraps` → publish → render the form → submit the
  token that render produced → the evidence row exists → the receipt verifies.
  It is the one document every user reads and was the only one nothing checked.

  It found real defects on its first run, all of them consequences of emitting
  fewer tables: capture marked a presentation accepted without asking whether
  the policy retains presentations, and receipts, verification, and the
  retention planner read optional annex tables unconditionally. Every
  association whose table is optional now answers "there is nothing here" when
  the table was never created — which is not a fallback but the exact truth,
  since without the table no row was ever written.

### Changed — the emitted footprint

- **The generated initializer states decisions, not defaults.** It carried about
  thirty live lines that assigned the gem's own default back to itself, so a
  reader could not tell which lines somebody had chosen and which were noise —
  and every one of them was a line to maintain in two places forever. Live lines
  are now only what the installer actually decided or detected; every other
  setting appears commented, with its default value, under prose that says what
  it does. A default install drops from about thirty live settings to three,
  plus the eleven request-evidence lines.

  Those eleven stay live even when every answer is `false`, deliberately: each
  is an answer to a question the installer asked, and "we decided not to collect
  this" is a decision worth reading rather than inferring from a file that does
  not mention it. The file says so where the rule is stated.
- **`clickwrap:install` emits only the tables an installation can put a row
  in.** Seven of the seventeen tables — persisted presentations, the
  request-evidence annex, chain heads, integrity attestations, external
  actions, disposition plans, legal holds — are each gated on a configuration
  that is off by default, so a default install could never write to any of
  them. A schema that contains them anyway claims capabilities and data
  categories the application does not have, which is exactly the impression
  this gem exists not to give. Each now arrives with its own flag
  (`--with-persisted-presentations`, `--with-request-evidence`,
  `--with-integrity`, `--with-retention-ops`, `--with-external-actions`),
  following the `clickwrap:hardening` precedent, and re-running the generator
  later with a flag adds that migration then.

  Enabling a request-evidence field implies `--with-request-evidence`: an
  installation that records IP addresses into a table it never created is not
  a schema choice, and the operator already answered the question that matters.

  The one failure mode this trade creates — turning a capability on and
  forgetting its migration — is caught three ways, each naming the exact
  command: at boot, by `bin/rails clickwrap:doctor`, and at the entry points
  no configuration announces (`authorize_external_action!`, legal holds,
  disposition planning). The boot check deliberately stays quiet while
  migrations are pending, because refusing to boot would make the fix
  unrunnable.

### Fixed — the two-audit adversarial review

Two independent audits read the gem as an unfamiliar developer would: one
followed the installer and the README literally, the other read the code
against its own claims. Everything below is a defect they evidenced.

- **The installer and the README never taught the auth door.** A Devise app
  that followed the post-install message verbatim created accounts with no
  evidence at all, silently — the gem is never called on that path, so nothing
  could warn about it. The post-install message and the README quickstart now
  both carry the door step, with the exact line, the host's own file path and
  class name, and the `devise_for ..., controllers:` route that makes the
  subclass reachable. "The installer detects your authentication stack and
  generates an explicit adapter" now says what it does: it detects, and prints
  the line for you to add.
- **`renew!`, `correct_declaration!`, and `change_consent_scope!` had no tests,
  no documentation, and no callers.** They are the conceptual spine of the six
  verbs, so they are now tested behaviorally — the event is appended, the
  earlier event still says exactly what it said and still verifies, and the new
  receipt verifies on its own — and the README shows each one with the sentence
  that says what it means. Writing those tests surfaced the reason nobody had
  used them: all three capture through a real presentation, so each needs a
  `submission:` exactly as the original statement did. That is correct — a
  correction, a renewal and a rescope are new statements by the same person,
  not administrative flags — but it was nowhere in the docs, and the README now
  says it.
- **`config.actor_class_name` now decides something.** The installer spends
  sixty lines, a `--actor-class` option, and a seven-line warning on this
  setting because "a wrong guess attributes evidence to the wrong kind of
  record for years" — which was not true, because nothing checked. The setting
  fed one error string, and `Configuration#actor_class` had no production
  caller at all. Capture now asserts the recorded actor is an instance of it,
  with an error that names the setting and points an organization at
  `acting_for:` where it belongs. System actors, anonymous actors, and literal
  references to actors in other systems are their own kinds, say so in the
  receipt, and are not checked against the class.
- **The receipt list authorized after paging.** Taking a page of rows and
  filtering them afterwards rendered "you have no receipts" whenever the
  viewer's newest page happened to be rows the host would not show them, while
  readable ones sat past the limit. Authorization now happens first, in bounded
  batches, and the actor is eager-loaded — a full page is three queries instead
  of fifty-two.
- **A presentation resolved its documents one statement at a time**, including
  the same document twice when two statements named it, even though documents
  are immutable and published and the answer cannot differ. Two queries now
  resolve every document a policy references.
- **`Clickwrap.reset!` left the presentation-manifest verifier memoized**, so a
  verifier built under the previous configuration survived the reset. The test
  suite had been resetting it by hand, which is why nothing caught it.
- **`Clickwrap.verify(event_id, …)` silently dropped its strictness keywords.**
  The event-id branch accepted `require_current_revision:` and then never
  received it, so a host asking "is this old evidence still good?" about one
  recorded act got an unqualified yes — worse than an error, because it looked
  like an answer. Both branches now answer the whole question: the event id
  compares the act's recorded policy revision against the wording compiled
  today, and re-derives the subject fingerprint from the live record when
  `subject:` is passed. A policy that is no longer declared answers
  `:unknown_policy` rather than passing, because "we can no longer check this"
  must never be spelled the same way as "this is fine". `Clickwrap.verify(event_id,
  subject:, require_current_revision: true)` is therefore the complete public
  form of that question, and nothing needs to reach into
  `Clickwrap::PolicyRevision` or `Clickwrap::SubjectFingerprint` to ask it.
  Verifying an event id also no longer writes: the revision comparison is by
  digest, so a read-only question stops creating a revision row as a side
  effect.
- **An unmounted engine used to sign 404 document links into evidence.** The
  document link goes into the presentation manifest, into the digest, and into
  the record of what was offered; built from an unmounted engine's routes it
  resolves to nothing, and nothing downstream can detect that afterwards
  because the digest is over the wrong link. Presenting now refuses at build
  time with the mount line in the sentence, `bin/rails clickwrap:doctor`
  reports the missing mount as a problem whenever any policy is compiled (it
  used to speak only about `requires_clickwrap` gates), and a non-interactive
  install mounts the engine and says so instead of silently taking the `[y/N]`
  default — `--skip-routes` is the one flag that declines.

### Added — the dream-API pass (driven by installing the gem into a second real application)

Two real installations wrote about a hundred lines of nearly identical glue
around this gem. That is the strongest possible evidence that the code belongs
in the gem, so each ceremony became behavior, working backwards from the API we
wished we had written.

- **`version:` is optional when the source names its own.** A document declared
  `from:` a file — or with inline `content:` — whose leading YAML front matter
  carries `clickwrap_version:` or `last_updated:` resolves its version label
  from there, so the file that *is* the legal text also names its version and
  there is no second copy of the label anywhere to drift. `clickwrap_version:`
  outranks `last_updated:` on purpose: a same-day correction that still changes
  bytes needs a fresh label while the date readers see stays put. Both host
  applications had written the same front-matter reader module to do this
  themselves; that module stops existing. The old failure mode was a label
  living in `config/clickwrap.rb` and words living in a file, changed in
  separate edits — which either publishes as "same label, different bytes"
  (refused at publish, correctly, but a step later than it needed to be) or
  quietly leaves the label describing text nobody is serving any more. A source
  with no front-matter key and no `version:` is now a boot failure with the fix
  in the sentence, and a `resolver:` source (whose bytes are only read at
  publish time) says exactly why it cannot name its own. Clickwrap never invents a
  label, because a policy that requires a current version cannot be satisfied
  by a guess.
- **`save`/`save!` pairing for doors and captures.** `register_with_clickwrap`
  (non-bang) absorbs a refused registration — a stale presentation, an unticked
  control, a validation the account failed — into the exact human sentences the
  Devise adapter paints, through one shared `Clickwrap::Registration.absorb_refusal`:
  inline via `clickwrap_errors` beside the control it belongs to, once on the
  record's `:base`, then `false`, ready for `render :new, status: :unprocessable_entity`.
  `capture_clickwrap` and `capture_clickwrap_and` do the same for
  `Clickwrap::CaptureRefused`, leaving the refusal on `clickwrap_refusal` with
  its `user_facing_message`. The old failure mode was every hand-rolled door
  writing its own rescue, each one slightly different, and one of them
  eventually rescuing too much. Infrastructure failures still escape every
  form — `Clickwrap::EventWriteFailed` is not a validation error to dress up —
  and lifecycle conflicts (`ReplayRejected`, `OneTimeAuthorizationConflict`)
  still raise, because "this was already done" needs a domain answer that no
  generic rescue can supply honestly.
- **`config.document_renderer = :markdown_rails` renders through the
  application's own renderer.** Content-file Rails apps already serve their
  public legal pages through a registered markdown-rails handler; when the same
  files are Clickwrap documents, what people accept and what the page serves
  must be the same bytes — same renderer, same options, no second sanitization
  pass changing entities behind the digest. Wiring that by hand meant a lambda,
  an engine name, gem versions, and a parity test copied between applications;
  this setting says it once, records honest provenance (the renderer class the
  application registered, plus the markdown-rails and Markdown-engine gem
  versions), and resolves the handler lazily at first render so initializer
  order cannot capture the stock default renderer instead of the application's.
  Its bound is stated rather than hidden: the renderer is called without a view
  context, exactly how a frozen snapshot must render, so Markdown that calls
  Rails view helpers fails loudly at publish and needs the explicit lambda form.
- **Publishing rides `db:prepare`.** The deploy step everyone forgets no longer
  exists: an enhanced `db:prepare` publishes declared documents, so by the time
  the server takes traffic every declared version has an immutable snapshot.
  The old failure mode was the worst kind of quiet — presentations refuse
  unpublished documents (the safe failure), so a forgotten `clickwrap:publish`
  became "nobody can sign up" some hours after a deploy that looked green. It
  is idempotent, silent when no documents are declared, and a sentence rather
  than a crash when the tables are not migrated yet; a real refusal fails the
  deploy out loud, which beats signups failing quietly later. Opt out with
  `config.publish_documents_after_database_preparation = false`.
- **`config.hotwire_native_document_links` answers the native question once.**
  One declarative seam does both halves coherently — the signed href
  (absolutized against a validated `https` canonical host, which may be a
  callable) and the navigation attributes (`target="_blank"`,
  `rel="noopener"`, `data-turbo="false"` for `:external_browser`; a plain link
  for `:same_screen`). It exists for one specific failure: on a native
  authentication sheet, a same-host document link is routed by the app itself,
  which pops the sheet and takes the half-filled signup form with it. Getting
  the href right in one place and the attributes right in another is exactly
  the kind of split that drifts. When set it answers native renders entirely;
  `config.document_link_html_options_with` goes on answering everything else,
  so an app needing different answers per screen keeps the per-request lambda.
- **The default `describe_authentication_with` no longer over-claims.** It now
  reports `{ method: :authenticated_session }` only when the controller's
  configured current-actor method actually returns someone, and `{}` otherwise.
  A signup form is not an authenticated session, and describing every request
  as authenticated merely because it passed through `ApplicationController` put
  a claim in the receipt that nobody had checked. It is deliberately gentler
  than the capture path's actor resolution: describing authentication is
  context, not identity, so a controller with no such method is `{}`, never an
  error.

### Added — installer improvements (driven by installing the gem into a template application)

- **Non-interactive runs skip the questions instead of jumbling them.** When
  `rails generate clickwrap:install` runs without a terminal (a piped or
  scripted run, CI, an AI agent), it now announces that it detected a
  non-interactive run and takes the same collect-nothing defaults as
  `--skip-questions`, rather than streaming interactive prompts into a pipe
  that would have taken every `[y/N]` default anyway.
- **Existing legal pages become the document source.** When the host already
  keeps both legal documents at a recognized convention — Sitepress-style
  `app/content/pages/legal/terms.html.md` + `privacy.html.md`, or a previous
  install's `app/content/legal/*.md` — the generated `config/clickwrap.rb`
  points its `from:` lines at those exact files and no placeholders are
  written. What people accept and what the public legal routes render must be
  the same bytes, and a second copy is how they silently stop being the same
  document. Placeholders are still written when no convention matches, and a
  convention only counts when both of its documents exist.

### Added — the hardening pass (driven by an independent adversarial audit of the first production integration)

- **Policy-declared tenant semantics: `tenant_is :not_applicable | :optional | :required`.**
  Presentation, capture, verification, and import all resolve the tenant
  through the policy's declaration, and the resolved tenant is signed into
  the presentation manifest — so a personal policy can never inherit an
  ambient organization from the session, and an organization member can no
  longer be dead-ended by a `presentation_tenant_mismatch` between a
  tenant-less render and a tenant-injecting submit. Withdrawal matches each
  grant under its own policy's semantics, so consent granted personally stays
  withdrawable after the person joins an organization; exemptions record the
  canonical tenant reference. Declare `tenant_is :not_applicable` explicitly
  on personal policies — it is the difference between "this evidence never
  changes identity" and "whatever organization happened to be current."
- **Import chronology and revision honesty.** An imported historical grant
  can never replace a newer live state (effective-time-first comparison, with
  server recording order as tie-breaker only); imported evidence carries an
  explicit legacy-import revision identity that can never satisfy
  `require_current_revision: true`; and **`counts_as_current: false`**
  quarantines an import — it satisfies no predicate, survives projection
  REBUILDS quarantined, and exists for exactly the case where counsel has not
  yet blessed a legacy source (a bundled checkbox, an unverified column).
  Import idempotency covers statement mappings and provenance.
- **Serialized evidence writes.** Every state-mutating path (capture, import,
  exemption, lifecycle transitions, provider outcomes, projection rebuild)
  takes a per-actor identity lock first and the chain head second, in one
  documented order, so concurrent writers block instead of deadlocking and
  lost-update races on statement states are gone. The concurrency lane runs
  on PostgreSQL and MySQL — SQLite cannot express row locks.
- **`recorded_after?` is off ULIDs.** Ordering questions are answered by a
  durable database sequence under a unique chain position; ULID comparison —
  process-local monotonicity — is no longer presented as an ordering
  guarantee anywhere. The sequence is the installation's PRIVATE order: it is
  deliberately absent from canonical bodies and receipts, because publishing
  a global counter would hand every receipt holder an enumerable census of
  installation activity.
- **Atomic protected outcomes.** `record_protected_outcome_with:` on a
  one-time authorization records the exact result of the protected action —
  built via `Clickwrap.protected_outcome`, digest-covered, committed in the
  same transaction, refused on recorder-version drift — so "this evidence
  authorized this exact operation" names the operation's amount, record, and
  state instead of implying them.
- **Immutable document navigation.** The signed manifest binds each
  statement's immutable document path; choice/radio statements render their
  document links (previously only checkboxes did); and
  `config.document_link_html_options_with` lets hosts choose HOW links open
  (evaluated in the rendering view, so `hotwire_native_app?` works) while the
  href itself is refused under any capitalization. The "opens in a new tab"
  hint renders only when the link actually does.
- **Engine route authorization.** Receipts and withdrawal routes require a
  present actor before the host callback runs, and the generated
  authorization example now guards `nil == nil` explicitly. Remediation
  tokens CARRY their signed tenant into presentation and capture instead of
  comparing it against an ambient value the engine's routes cannot have.
- **Evidence-contract model links.** `has_clickwrap_evidence` takes the full
  contract (`policy:`, `statement:`, `actor:`, `subject:`, optional
  `tenant:`/`represented_party:`/`required_for_new_records:`), validates a
  linked event against it, refuses link replacement, and supports model-first
  deployments (inert until the column exists; strict from then on).
- **Submission hardening.** Forged envelope fields raise instead of being
  dropped; answers are bounded at `Submission::MAX_ANSWER_LENGTH` characters
  and refused — never truncated — beyond it (an answer is a checkbox state or
  a declared choice name, not free text).
- Atomic represented-party creation (`create_represented_party_with_clickwrap`
  and `including_when_this_action_creates_the_organization:`), atomic local
  projections for external actions, request-aware geolocation provenance, and
  pending-receipt answer readers (`answer_for`, `answered?`, `granted?`,
  `declined?`) that read the validated event being committed instead of
  re-parsing browser params.

Changes driven by the first production host application:

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

- **Public forms that find or create their record:**
  `register!(..., actor_may_already_exist: true)`. The lead-capture /
  newsletter shape — an anonymous visitor submits a public form and the host
  resolves the row by typed email — is one `register_with_clickwrap` call for
  both cases now. When the submission created the row, attribution stays
  `account_registration`; when it matched an existing row, the receipt
  records the new `public_form` attribution instead, because no account was
  created by the act. Without the explicit option, a persisted prospective
  actor is still refused (that is usually a bug — the host meant `capture!`
  with `actor:`), and the refusal teaches the option. (Forced by migrating a
  production lead-magnet funnel whose leads upsert by email.)
- **`Clickwrap::CaptureRefused` with `#user_facing_message`.** Every refusal a
  person can cause from a form — a stale or missing presentation, an
  unparseable submission, a declined required statement — now shares one
  exception superclass carrying a localized sentence fit to show them, so a
  host controller handles the whole family in one rescue:
  `rescue Clickwrap::CaptureRefused => refusal; redirect_to ..., alert:
  refusal.user_facing_message`. Infrastructure failures stay outside the
  family and stay loud. (Extracted from a real host that had grown five
  hand-written rescue sites for the same distinctions.)
- **`has_clickwrap_evidence` + `bin/rails generate clickwrap:link TABLE`.**
  One macro and one generator for the row-level link between a domain record
  and the capture that authorized it: the generator writes the
  `clickwrap_event_id` column migration (ULID string, indexed, nullable, no
  foreign key — each deliberate, and the migration says why), and the macro
  gives the model `clickwrap_event` and `clickwrap_receipt`, so
  `withdrawal.clickwrap_receipt.verify` is one line years later.
- **`Result#recorded_after?(other)`** on verification results — enforce
  evidence ordering ("the declaration must postdate the preparation") without
  hosts comparing event ids by hand; accepts another result or a bare event
  id and is false whenever either side is missing.
- The installer's post-install checklist now includes the test-suite setup:
  include `Clickwrap::TestHelpers`, publish once per parallel worker and once
  per process, and read submissions off rendered pages with
  `clickwrap_params_from` — presentation tokens are signed and session-bound,
  so tests cannot fabricate them by hand (that is the point).
- **[Integrating guide](guides/integrating.md)** — the battle-tested playbook
  from migrating a production application onto the gem end to end: install
  order, pointing documents at real legal content, test setup, Devise
  dual-write bridges, custom surfaces, money-path protection, legacy import,
  request-evidence enablement, and the dual-write → dual-belt → retire
  rollout doctrine.
- **View helpers for custom surfaces** (`Clickwrap::ViewHelpers`, available in
  every view): `clickwrap_presentation_token_field`,
  `clickwrap_statement_check_box`, `clickwrap_statement_radio_button`, and
  `clickwrap_submit_button` own the three contracts a hand-written form gets
  wrong silently — the envelope name, the statement control names/ids, and a
  call to action worded by the signed manifest itself. The host owns every
  class and wrapper around them. (Extracted from the first production host's money-path
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
