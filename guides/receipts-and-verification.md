# Receipts and verification

A receipt answers "show me exactly what the application recorded." There is one canonical JSON body
per event and one HTML projection of the same facts — never a different set of facts, and never
a stronger claim than the JSON makes.

```ruby
receipt = Clickwrap.receipt(event_id)

receipt.to_canonical_json     # the verifiable bytes
receipt.to_html               # the human projection
receipt.verify                # against this application's data
```

`to_pdf` deliberately raises. A PDF library is not a dependency of an evidence gem, and a PDF
is a rendering of the receipt rather than the record. Run your own pipeline over `to_html` if
you need one.

---

## Anatomy

Everything below describes the released receipt schema. Keys whose value would be empty are
omitted rather than written as `null` — the one exception being request evidence, which always
reports an explicit state object.

### Top level

| Key | What it holds |
|---|---|
| `schema` | `"clickwrap.receipt.v1"`. A verifier that does not know this name stops rather than guessing |
| `event_id` | The stable identifier the domain row can reference |
| `event_type` | What produced the event: `capture`, `withdrawal`, `correction`, `supersession`, `expiry`, `consumption`, `revocation`, `renewal`, `scope_change`, `exemption`, `imported_legacy`, `external_receipt`, `disposition`, `legal_hold_placed`, `legal_hold_released`, `receipt_access`, or `provider_outcome` |
| `recorded_at_by_server` | When this application wrote the row down |
| `occurred_at` | When the act happened, according to whatever recorded it. For a live capture these coincide; for an import they usually do not, and the gap is itself evidence |
| `verifier_instructions` | A sentence telling a reader how to check the file without this application |

### `policy`

| Key | What it holds |
|---|---|
| `key` | The policy key as declared in `Clickwrap.policy` |
| `revision` | The digest of the compiled policy revision frozen at capture. Historical receipts do not need current source code to explain what the policy meant |
| `retention_class` | Which retention class governed this event |

### `actor`

| Key | What it holds |
|---|---|
| `type` | The actor model's class name |
| `reference` | The stable reference produced by `config.identify_actor_with`: a model's `clickwrap_actor_reference`, otherwise GlobalID when available, otherwise `ClassName/id`. The recorded string survives the row being deleted |
| `attribution.method` | One of `authenticated_session`, `account_registration`, `operator_session`, `api_credential`, `anonymous_identifier`, `system_process`, `imported_provider`, `unknown`. None of these is an identity claim; each says which application-supplied context was recorded |
| `attribution.authenticated` | True only when the method was `authenticated_session` |
| `authentication_method` | The host's own description from `config.describe_authentication_with` |
| `snapshot` | Only the actor fields the host named in `config.snapshot_actor_with`. Clickwrap never serializes a whole model into evidence |
| `acting_for` | Present only for delegated action: the represented party's type and reference, the authority source, the authority role, and when authority was verified — as four separate facts. Clickwrap does not decide whether that authority was sufficient |
| `tenant` | The tenant key, when the capture had one |
| `subject.reference` / `subject.fingerprint` | Which domain object the act was about, and the host-computed fingerprint that binds it |

### `acts[]`

One entry per statement. A policy with several statements produces one event and one receipt,
but the statements never collapse into one meaning.

| Key | What it holds |
|---|---|
| `statement` | The statement key |
| `kind` | `agreement`, `acknowledgment`, `consent`, `declaration`, `attestation`, or `authorization` |
| `action` | What was recorded for this kind — see [the lifecycle guide](consent-and-lifecycle.md) |
| `assertion` | The **resolved sentence** bound to the generated presentation, not an I18n key. A key's meaning can change in a later deploy; then the receipt no longer says what the server asked |
| `locale` | The locale that sentence was resolved in |
| `required` / `answered` / `answer` | Whether the statement was required, whether it was answered, and what the answer was |
| `purpose` | The purpose key, for consent |
| `expires_at` | When this act stops being current, for kinds that can expire |
| `one_time` | Present only when the act is a one-time authorization |
| `subject_fingerprint` | The fingerprint recorded for this statement's subject binding |

### `documents[]`

| Key | What it holds |
|---|---|
| `statement` | Which statement this document was attached to |
| `key`, `version`, `locale` | Which exact document version was bound |
| `source_media_type` / `source_digest` | The media type and digest of the original source bytes, as they stood at capture |
| `rendered_media_type` / `rendered_digest` | The media type and digest of the rendered representation actually offered |
| `renderer` | The named renderer and sanitizer versions that produced the rendered bytes, when applicable |
| `ordinal` | The document's order within the presentation |

Two digests, because "this Markdown file existed" and "this rendered representation was
offered" are different claims. The digests are copied onto the event rather than only
referenced, so verification can detect a document-version row edited in place instead of
trusting the column it is supposed to be checking.

### `presentation`

| Key | What it holds |
|---|---|
| `manifest_digest` | The canonical digest of the presentation manifest the server generated |
| `submit_button_text` | The exact call-to-action wording in that manifest |
| `locale` | The locale the presentation was rendered in |
| `capture_channel` | `web_browser`, `native_app`, `api_client`, `operator`, `background_job`, `imported_provider`, or `system` |
| `offered_at` | When the manifest was issued |
| `proves` | A sentence, inside the receipt itself, saying what this establishes: that the server generated the manifest and accepted a submission bound to it — and not that the person read or understood the documents, saw particular pixels, or received a sufficient interface |

### `outcome`, `lifecycle`, `provider`

`outcome` is the protected action's in-transaction result snapshot when the policy configured
`record_protected_outcome_with`. The callback receives the block's return value and should use
`Clickwrap.protected_outcome(action:, record:, facts:, state: nil)`. The resulting reference,
non-empty canonical facts, and fingerprint over the complete claim are validated before commit;
a malformed or stale fingerprint rolls the domain action and evidence back together. Without a
recorder, the receipt says only that the named policy, bound subject, evidence event, and block
committed together — Clickwrap does not guess what a host method meant. A pending external outbox
does not claim a completed local outcome; its provider result is appended later.

`lifecycle` carries `root_event_id`, `predecessor_event_id`, and every successor event with its
type, time, reason, canonical event body, and event digest. This is where a withdrawal,
correction, supersession, expiry, consumption, or disposition shows up. Ordinary lifecycle
changes append instead of overwriting the earlier event; reviewed core disposition is the named
exception that removes a fixed payload while retaining a linked tombstone.

That makes an exported receipt a projection at the moment it was exported. A later export may
add lifecycle successors or integrity attestations, so its top-level `receipt_digest` may be
different even though both exports are valid. The embedded canonical `event` object and its
`integrity.event_digest` are the stable historical anchor for the original event: lifecycle
history grows by appending linked events rather than changing that body. Keep an exported file
if the exact export itself matters; do not use byte equality between exports as a current-state
test.

`provider` appears only on imported external receipts, and carries the provider name, its event
ID, its verification status, and a `note` stating plainly that Clickwrap did not present this
content or observe this action.

### `request_evidence`

Three keys — `ip_address`, `browser_user_agent`, `ip_geolocation` — each always present, each
carrying a `state`. See [the request-evidence guide](request-evidence.md) for the field-level
dictionary. What matters here is that raw values are **not** in the canonical body by default.
They live in a separately encrypted annex with its own authorization, retention, hold, and
disposition state, and the body carries only a keyed digest binding the two.

That boundary is the whole reason the annex exists. Welding an IP address into the core event
would force its schedule to match the agreement payload. Here each annex category can go on its
own clock while the retained core event stays intact and verifiable.

An export that reveals request evidence is a different document from a redacted one, so it
carries a different `receipt_digest`. That is correct: each file verifies as the file it
actually is.

### `retention`

`class`, `core_event_retained_until`, `retention_rule`, `core_event_disposed_at`, and
`on_legal_hold`. See [the retention guide](retention-and-legal-holds.md).

### `system`

`gem_version`, `application_version`, `template_version`, `canonical_schema_version`, and
`verifier_version` — so a reader can tell which code wrote the receipt and which code read it.

---

## The two digests

`integrity` carries both `receipt_digest` and `event_digest`. They are different values, they
cover different bytes, and confusing them is the single easiest way to overstate what a
verification result means.

| | `integrity.receipt_digest` | `integrity.event_digest` |
|---|---|---|
| Covers | This receipt body, with only `integrity.receipt_digest` removed, canonicalized per RFC 8785 | The **event's own** canonical body embedded at top-level `event`: a different object, with different keys, built when the event was written |
| Computed | When the receipt is produced, by whoever produced it | Once, at capture, and stored on the event row |
| Checkable from a file alone | **Yes.** | **Yes while the event payload is retained.** After reviewed core disposition, the verifier checks the retained tombstone and exact digest-linked disposition successor instead and labels the original digest check incomplete |
| Answers | "Has this exported projection changed since this digest was taken?" | "Does the embedded historical event body match the digest recorded when that event was finalized?" In-app verification additionally compares against the database row |

The exclusion of `integrity` is not a convenience. A digest cannot cover itself: the moment it
is written into the object, the object's bytes change and no amount of recomputation converges.
So the digest is taken over the body before `integrity.receipt_digest` is attached, and
verification reproduces that by removing exactly that field. Everything else — including the
rest of `integrity`, `verifier_instructions`, and any host `x_`-prefixed extension — is inside the digest. A key
excluded without being named would be a key anyone could edit freely.

The receipt embeds the event's canonical body under `event`, so the standalone verifier re-derives
`event_digest` and also checks every duplicated receipt projection against it. If reviewed
retention has removed the original payload, it cannot truthfully re-derive those deleted bytes;
it instead requires a minimal tombstone and exactly one digest-checked `disposition` successor
whose event ID, predecessor/root link, original digest, and disposition time agree. That check is
reported as incomplete/documented disposition, never as an ordinary verifying event digest.

`integrity` also carries `previous_event_digest`, `chain_scope`, and `chain_sequence` when
chaining is on; per-category request-evidence binding digests, algorithm, key ID, and binding
status; immutable timestamp/anchor attestation results; and `tier` plus `detects`, which state in
the receipt itself exactly what the assurance level detects. See [the integrity guide](integrity.md).

---

## Canonicalization

Receipts are digested and verified by code that may be years newer than the code that wrote
them, and by verifiers written in other languages. So the bytes have to be reproducible from
the data alone: no Ruby object serialization, no YAML, no hash insertion order, no database
column order, no locale-dependent number formatting.

The base is the [JSON Canonicalization Scheme, RFC 8785](https://www.rfc-editor.org/rfc/rfc8785)
*(technical standard)*. Two of its rules bite in practice, and Clickwrap implements both
explicitly rather than relying on Ruby's defaults:

- **Object keys sort by UTF-16 code units**, not UTF-8 bytes. Ruby compares strings by UTF-8,
  which orders characters outside the Basic Multilingual Plane differently, so keys are encoded
  to UTF-16BE before comparison.
- **Numbers follow the ECMAScript `Number::toString` algorithm.** Ruby writes `1.0` where
  ECMAScript writes `1`, and `1.0e-05` where ECMAScript writes `0.00001`. Clickwrap rebuilds
  the ECMAScript form from Ruby's shortest round-trip digits.

Integers whose magnitude exceeds 2^53 − 1 raise rather than serialize, because they cannot
survive the IEEE 754 double round trip RFC 8785 assumes and another verifier could not
reproduce the bytes. Record large identifiers as strings.

### The Clickwrap profile

Five additions on top of RFC 8785. They exist so two verifiers never disagree about what a
value meant:

| Rule | Why |
|---|---|
| **Timestamps are UTC strings with exactly six fractional digits and a `Z` suffix** (`"2026-08-15T12:34:56.123456Z"`) | Fixed width, so nobody has to decide whether a trailing zero was significant. Local offsets and variable precision are two verifiers' worth of disagreement |
| **Digests are `"<algorithm>:<lowercase hex>"`** (`"sha256:9f86d0…"`) | An auditor never has to guess which function produced a bare hex string, and a future release can add an algorithm without making old events unreadable. Keyed digests use `"hmac-sha256:…"` |
| **Identifiers are strings, never numbers** | A numeric ID is a lossy round trip through a double and a formatting decision waiting to happen |
| **A value that was never collected is an explicit state object**, never `null` and never a missing key | `null` and "absent" both mean four different things — not configured, unavailable, redacted, deleted. The state object says which |
| **Host extensions use keys prefixed `x_`** | So a verifier can tell your additions from the schema's, and so your additions are still inside the digest |

---

## Verifying inside the application

```ruby
result = receipt.verify
result.success?     # => true
result.error        # => :declaration_expired, or nil
result.message      # localized human explanation
result.details      # stable machine-readable facts, no surprise personal data
```

This path has the database, so it checks what a file cannot: that the event's own digest still
matches the row, that document-version rows still carry the digests the event recorded, that
the lifecycle state is what the policy requires, and that chain links line up with their
neighbours.

Across the whole store, or one event:

```bash
bin/rails clickwrap:verify
bin/rails clickwrap:verify EVENT_ID
```

Chain walks are their own operation and report their own vocabulary:

```ruby
result = Clickwrap::Integrity::Chain.verify
result.success?      # => true
result.counts        # => {"checked" => …, "verified" => …, "breaks" => 0, "scopes" => …}
result.first_break   # => nil, or a Break with a stable `reason`
```

The break reasons are stable symbols so a monitor can branch on them without matching English:
`digest_does_not_match`, `previous_digest_does_not_link`, `sequence_gap`,
`earlier_events_missing`.

---

## Verifying outside the application

```ruby
Clickwrap::Receipt.verify(canonical_json, documents: document_files)
```

```bash
clickwrap verify receipt.json --documents ./receipt-documents
clickwrap verify receipt.json --documents ./receipt-documents --json
```

The CLI's dependency list is the feature. It requires JSON, the canonicalizer, the digest
helpers, the error classes, and the version constants — no Rails, no Active Record, no
database, no engine, no host application, no policy source, no network. A verifier that had to
boot the application which produced the evidence could only ever tell you that the application
agrees with itself.

It runs the applicable checks below and reports each one as passed, failed, or **skipped**:

| Check | What it does |
|---|---|
| `json_parses` | The file is a JSON object |
| `known_schema` | The `schema` value is one this verifier knows. An unknown schema **stops** verification rather than guessing at the meaning of a newer format |
| `canonical_bytes` | Whether the bytes are already canonical. Non-canonical bytes are re-canonicalized and reported, not failed — pretty-printing a receipt on its way through a bug tracker changes formatting, not meaning |
| `receipt_digest` | The recorded digest matches the canonicalized body with only `integrity.receipt_digest` excluded |
| `event_digest` | The embedded canonical event and every duplicated projection match the recorded event digest; disposed payloads take the documented-disposition path described above |
| `lifecycle:<event_id>` | Every embedded successor's canonical body, digest, type, and root/predecessor relationship agree |
| `integrity_attestation:<id>` | Every included attestation digest verifies and an upgraded tier has the exact verified capability it claims |
| `document:<key>@<version>` | Each supplied file hashes to the digest the receipt recorded. A document whose bytes you did not bring is reported `not_supplied` |
| `chain_linkage` | Chain fields, when present, are internally coherent. Not chained is reported as a configuration fact, not a finding |

Three states, not two, everywhere. A check that could not run is neither a pass nor a failure,
and collapsing it into either turns "we did not look" into "we looked and it was fine." A
skipped check never makes a result succeed and never makes it fail; it stays visible.

Files are matched to documents by key, version, and locale, most specific first:
`terms-2026-08-15-en.md`, then `terms-2026-08-15.md`, then `terms.en.md`, then `terms.md`, then
any file whose basename starts with `terms-`.

Exit status is `0` when every required check passed, `1` when any check failed, and `2` when no
check failed but a required document artifact was not supplied.

---

## What a successful verification does and does not establish

It **does** establish:

- the file is well-formed JSON in a receipt schema this verifier knows by name;
- its bytes are canonical under RFC 8785, so two readers digest the same thing;
- the digest the receipt carries matches the body it travels with, so accidental or ordinary
  modification of those bytes is detected;
- the embedded event body and duplicated receipt projections match the event digest, or the
  receipt contains a coherent documented core disposition instead of pretending deleted bytes
  were re-derived;
- each document file you supplied hashes to the digest the receipt recorded for it; and
- any chain links present are consistent with each other.

It does **not** establish:

- **that the receipt was not fabricated.** A self-contained file verifying against itself shows
  internal consistency and nothing about origin. A party who controlled the application, the
  database, and the export could have produced every byte in it, including the digest, and this
  verifier would say "verified" — because the only thing it can compare the bytes against is
  the bytes;
- **when anything happened.** `recorded_at_by_server` is a time an application server wrote
  down. It is the server's own clock, attested by nobody else;
- **who acted.** An actor reference identifies a record in somebody's database, not a person;
- **that a chain was not rewritten.** A single receipt can only show its own links are
  coherent. Proving the chain itself is intact needs the neighbouring receipts and a head held
  somewhere the database operator does not control;
- **that any of it is sufficient, adequately presented, or admissible anywhere.** That is not a
  property of a file.

Origin and time evidence come from things this verifier cannot supply on its own: a verified
outside publication of the exact event-chain snapshot, an RFC 3161 or trust-service token over
the exact event digest, or a provider's own signed receipt. Where those exist they are reported as
exactly the assurance they supply. Where they do not, their absence is visible rather than
papered over by a check mark. Every result, in both the library and the CLI, prints that caveat
alongside the verdict.

---

## Exporting

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

There is deliberately no `include_sensitive_context: true`. One flag that turns on three
different categories of personal data is exactly the kind of option that makes an operator's
intent unreviewable a year later.

Naming any category as `true` requires a non-empty `because:` and a `true` from
`config.authorize_unredacted_request_evidence_access_with`; the default callback returns
`false` for everyone. Every export appends a `ReceiptAccess` row recording who asked, why, and
which categories were included. Foreign event IDs return not found, so existence is not leaked.

---

## The golden-fixture policy

Released evidence formats are permanent. That is a stronger promise than semantic versioning,
and it has three parts the project holds itself to:

1. **`ReceiptVerifier::KNOWN_SCHEMAS` only ever grows.** A new gem version may stop *creating*
   an old schema. It must never stop *verifying* one, because receipts exported under it are
   out in the world and their whole value is that they still check out years later.
2. **A format change means a new explicit schema and a new branch of verification logic** —
   never a silent reinterpretation of an old name. `CANONICAL_SCHEMA_VERSION` is deliberately
   independent of the gem `VERSION`, and `VERIFIER_VERSION` moves only when receiver-side
   verification changes in a way an auditor should be able to see in a receipt.
3. **Every released receipt schema, canonicalization profile, digest field, event action, and
   lifecycle meaning gets a permanent fixture**, and the suite verifies every previously
   released format on every run. The fixtures live in `test/fixtures/receipts/` — real
   receipts, byte for byte, exactly as an earlier version exported them — with their document
   bytes beside them, and `test/golden_receipts_test.rb` runs the current verifier against all
   of them. They are never regenerated. When a format legitimately changes, the correct move is
   to add a fixture under the new schema name and leave the old ones alone: a fixture updated
   to match new behavior has stopped testing anything.

Two consequences for contributors. Anything touching public vocabulary or an evidence claim — a
receipt field, a lifecycle meaning, a sentence a receipt prints about what it proves — needs
the documentation change alongside the code plus a note on what happens to receipts already
written under the old behavior. And released migrations are never edited underneath an
installed application; upgrades add migrations and report their exact effects.

---

## Sources

| Source | Class |
|---|---|
| [RFC 8785, JSON Canonicalization Scheme](https://www.rfc-editor.org/rfc/rfc8785) | Technical standard |
| [NIST FIPS 180-4](https://csrc.nist.gov/pubs/fips/180-4/upd1/final) — SHA-2 is a hash standard, not a signature, identity, or time source | Technical standard |
| [RFC 3161](https://www.rfc-editor.org/info/rfc3161/) — a separate time-stamp protocol | Technical standard |
| The profile rules, the two-digest split, and the export design | Product-design inference |
