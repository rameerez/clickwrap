# Integrity: five tiers and what each one actually detects

Clickwrap starts useful with an ordinary Rails database and lets serious applications add
assurance without changing the capture API. What does not change with the tier is the
vocabulary: each tier states exactly what it detects, and the receipt prints that sentence
itself so nobody has to infer it from a green check mark.

## Three things that are not the same thing

This is the section to read before the tier table, because most overclaims start by blurring
these together.

**SHA-2 is a hash standard.** It says nothing about who computed a digest, when, or whether
they were entitled to. [NIST FIPS 180-4](https://csrc.nist.gov/pubs/fips/180-4/upd1/final)
*(technical standard)*. A hash is not a signature, not an identity, and not a time source.

**RFC 3161 is a time-stamp protocol.** A time-stamp authority returns a token over a digest you
gave it. What that token is worth depends entirely on that authority, its practice statement,
its certificate status, and what a reader is willing to accept about it.
[RFC 3161](https://www.rfc-editor.org/info/rfc3161/) *(technical standard)*.

**eIDAS is a regulation about the legal effect of electronic signatures and seals.** Article 25
assigns a distinct effect to signatures at its qualified level, which is a different thing
again from a hash and from a timestamp token.
[Regulation (EU) No 910/2014, Article 25](https://eur-lex.europa.eu/eli/reg/2014/910/2024-05-20/eng)
*(law)*. Whether a given provider's output has that effect is a question about that provider,
not about this gem.

Two consequences that hold everywhere in Clickwrap:

- **A local hash detects modification of the bytes it covers, and nothing more.** It does not
  establish who produced those bytes, when, or that a party controlling both the application
  and the database could not have written the record and its digest together. The baseline
  receipt says exactly that, in the receipt.
- **`recorded_at_by_server` is the application server's own clock.** It is called that
  everywhere — in the column name, in the receipt, in the API — precisely so it is never
  mistaken for a time attested by a third party. Clickwrap has no method, field, or option
  named `signed_at`. A timestamp authority supplies something different, and when one is
  configured its token and its own reported time are stored and labeled as the provider's.

---

## The five tiers

| Tier | What you turn on | The exact claim |
|---|---|---|
| **Baseline** | Nothing. `config.digest_canonical_receipts_with = :sha256` is the default | The recorded digest detects accidental or ordinary modification of the bytes it covers. It does not establish who produced them, when, or that a party controlling both the application and the database could not have written both the record and the digest |
| **Database hardening** | `bin/rails generate clickwrap:hardening --database` and a migration | Rejects unsupported mutation paths within the documented database threat model. On PostgreSQL this is real update and delete protection; on SQLite and MySQL the generator says plainly what the database can and cannot reject rather than emitting something that looks like protection and is not |
| **Chained history** | `config.chain_event_history_with = :sha256` | Each event carries the digest of the one before it, so an event later rewritten or removed stops linking up with its successors. This makes a rewrite of history detectable for as long as the chain head remains trustworthy — and no more than that |
| **Independent anchoring** | `config.anchor_event_history_with = MyAnchor.new` | The exact chain scope, sequence, event ID, and event digest committed for each event are offered to an outside publication service. The tier upgrades only when the adapter records and verifies that exact snapshot; the claim is only ever as strong as the publication and its verifier |
| **Timestamp or trust-service provider** | `config.timestamp_receipts_with = MyRfc3161Provider.new` | Preserves exactly the assurance and validation status that provider supplies, verbatim. If the provider's own status is "unknown" or "expired", that is what travels into the receipt |

Three notes on the honest edges of that table.

**Chaining does not stop a fully privileged actor.** Whoever can write the events table can
usually write the chain-head table too, and a head living in the same database as the chain
cannot say otherwise. What the chain reliably catches is ordinary corruption, a well-meant
`update_column`, a restored partial backup, and a row edited by hand — which is most of what
actually goes wrong. It is precisely the remaining gap that the anchor adapter addresses.

**Anchoring and timestamps are adapter contracts, not bundled providers.** Both configuration
settings default to `nil`, so no provider call or attestation row exists until the host chooses
an adapter. `Clickwrap::Integrity::Anchor` and `Clickwrap::Integrity::Timestamp` are reference
base classes with explicit unavailable results; they are not installed implicitly. Clickwrap
ships no RFC 3161 client — no ASN.1 encoder, no HTTP client, no certificate-chain validation —
and adds no dependency that would. A host that needs one supplies an adapter that speaks to its
chosen service.

**The receipt's `integrity.tier` reports recorded, verified evidence — never configuration
alone.** It is `third_party_timestamp` only when an independently-verifiable timestamp
attestation over the event digest verifies; otherwise `external_event_anchoring` only when an
outside-publication attestation over the exact chain snapshot verifies; otherwise
`chained_history` when the event carries a chain scope; otherwise `baseline`. Database
hardening is checked separately by `bin/rails clickwrap:doctor`. Unavailable, failed, and issued
but unverified provider results remain visible in `integrity.attestations` without upgrading the
tier.

Enable what you need, explicitly:

```ruby
config.digest_canonical_receipts_with = :sha256   # or :sha384, :sha512
config.chain_event_history_with       = :sha256
config.anchor_event_history_with      = MyIndependentAnchor.new
config.timestamp_receipts_with        = MyRfc3161TimestampProvider.new
```

Every digest stored anywhere carries its algorithm name as an `"<algorithm>:<hex>"` prefix, so
a future release can add an algorithm without making old events unverifiable, and an auditor
never has to guess which function produced a bare hex string.

### External attestations happen after commit

Timestamp and anchor providers cannot participate in the database transaction that records the
event and the protected host action. Clickwrap therefore calls them after commit. A provider
outage cannot undo a capture that already committed. Each ordinary result — `verified`,
`issued_unverified`, or `unavailable` — becomes an immutable attestation row. An adapter
exception becomes a `failed` row when the database is available and is also reported through
`report_after_commit_failure_with`.

There is one unavoidable crash window: a process can die after the event commits, or after a
provider accepts a request but before the local attestation row commits. Inventory missing
attempts with `clickwrap:doctor`, then reconcile them explicitly:

```bash
bin/rails clickwrap:integrity:attest_missing
bin/rails clickwrap:integrity:attest_missing SINCE=2026-08-15T00:00:00Z LIMIT=100
bin/rails clickwrap:integrity:attest_missing RETRY_FAILED_ATTESTATIONS=1
```

The task may call external providers. It skips events that already have a result; failed results
are retried only with `RETRY_FAILED_ATTESTATIONS=1`. This is at-least-once recovery, not
exactly-once delivery: if the provider accepted a request before the process died, a retry can
create another valid provider record. Timestamp adapters should use the event digest, and anchor
adapters the exact chain snapshot, as their provider-side idempotency input. Clickwrap preserves
every result rather than claiming certainty it cannot have.

Run verification continuously rather than at audit time:

```bash
bin/rails clickwrap:verify
bin/rails clickwrap:verify EVENT_ID
```

---

## Threat model: what happens if

Each row is a scenario the design has to survive, drawn from the product threat model. "What
Clickwrap does" is a statement about mechanism, not a guarantee about outcomes.

### The submitted request

| What happens if | What Clickwrap does |
|---|---|
| A crafted POST names a different policy, document, version, validity, or purpose | None of those are client inputs. The browser receives a signed presentation token and returns answers; the policy key, revision, document versions, validity window, subject binding, retention rule, and request-evidence fields are resolved server-side and rechecked inside the transaction |
| A stale presentation is submitted after a deploy | The manifest binds the render to the submit. A token issued against an older revision is rejected with `presentation_invalid` or `presentation_expired`, so a deploy between GET and POST never records a version the actor was not offered |
| An attacker swaps the actor, subject, or tenant inside a token | Each binding is checked: `presentation_actor_mismatch`, `presentation_subject_mismatch`, `presentation_tenant_mismatch`, plus `wrong_actor` / `wrong_subject` / `wrong_tenant` at verification |
| A double-click or a replay creates a duplicate event or a second protected action | Idempotency keys and subject locks are acquired inside the transaction. An identical key returns the original result without running the block twice; a conflicting replay fails with a stable `replay_rejected` |
| CSRF, session fixation, or a cross-account submission | Rails' own CSRF, session, and authentication protections remain host responsibilities. Clickwrap adds the actor/tenant/subject binding checks above on top of them |

### The data at rest

| What happens if | What Clickwrap does |
|---|---|
| A privileged application or database actor updates or deletes evidence | Events, statements, and document bindings refuse ordinary updates and destroys at the model layer. Four event columns have named mutable roles (`core_event_disposed_at`, `core_event_disposition_event_id`, `on_legal_hold`, `request_evidence_id`); reviewed core disposition also clears a fixed payload write set while atomically appending its digest-linked disposition event. Optional database hardening pushes the documented write sets into PostgreSQL. Neither stops somebody with full database access; digest/chain verification detects covered changes, and a verified outside publication narrows the gap further |
| A fully privileged actor rewrites the hash chain along with the events | The chain alone cannot detect this, and this guide says so rather than implying otherwise. That is what the independent anchor adapter is for, and the claim is then only as strong as the anchor |
| Signing or encryption keys rotate, or leak | Keys come from Rails credentials or a host key provider, and rotate with versioned key identifiers. The annex binding digest records its algorithm and a key identifier so a later reader can tell which key produced it |
| The server clock is wrong | Nothing here can fix that, and nothing here pretends to. `recorded_at_by_server` is labeled as the server's clock. A timestamp provider is the mechanism that adds a second, independent opinion about time |
| Algorithm or canonicalization changes make old events unreadable | Released formats are permanent: `KNOWN_SCHEMAS` only grows, a format change means a new explicit schema plus a verifier branch, and every previously released format keeps verifying. See [the golden-fixture policy](receipts-and-verification.md#the-golden-fixture-policy) |
| A mutable document source changes behind a version label | Publishing reads exact bytes and refuses to reuse a version label for different bytes. Export never fetches a live URL and calls it historical evidence. Event documents carry the digests as they stood at capture, so a document row edited in place is a detectable finding rather than a silent substitution |

### The optional request evidence

| What happens if | What Clickwrap does |
|---|---|
| A spoofed `X-Forwarded-For` or `CF-*` header is recorded as trusted evidence | The reader is host-configured and the receipt records which reader ran. A value containing a comma is refused outright rather than stored as an observation. Cloudflare-derived fields are marked host-verified only when the host explicitly asserts a verified path. See [the trusted-proxy section](request-evidence.md#trusted-proxies-and-why-requestremote_ip-alone-is-not-enough) |
| Client parameters masquerade as server-observed values | The form helper renders no hidden field for any of them, and submitted keys with those names are ignored. A native or API client's values stay labeled `client_reported_*` forever |
| IP-derived coordinates are presented as a physical location, or used to pick governing law | Every stored estimate carries `was_estimated`, its provider, its resolution time, and any accuracy metadata, and the receipt prints a sentence saying it is one provider's estimate about an address. Clickwrap never infers jurisdiction, law, or eligibility from geolocation |
| An opaque profile switch quietly enables new personal-data fields after an upgrade | There is no such switch. Every field is its own named setting, and enabling one never enables another category |
| Geolocation is retained without its provenance, or presented as several independent proofs | Provenance is not a policy choice: provider, source, estimated status, resolution time, and any accuracy or database metadata travel with any stored result and with any failure to produce one. Provider-derived country, region, city, postal code, and coordinates are one correlated estimate, not independent witnesses |
| A raw IP address or user-agent leaks through logs, errors, metrics, or a default export | Values are encrypted at rest by default, excluded from ordinary logs and metrics, absent from default exports, and never included in exception messages — a `fail_if_unavailable` error names the policy, the category, and the reason, never the value. OWASP's guidance on protected logging, sensitive-data discipline, and retention controls is the reference point ([Logging Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html)) *(vendor/industry guidance)* |
| Personal request evidence is buried so deep in immutable payloads that required deletion is impossible | It is not in the immutable payload at all. The annex is a separate table with its own schedule, and the event's canonical body excludes every annex value, so deletion cannot break verification |

### Retention and lifecycle

| What happens if | What Clickwrap does |
|---|---|
| Deleting an actor cascades and destroys the evidence | `has_clickwraps` adds no `dependent: :destroy`. The actor link nullifies and a stable pseudonymous reference remains |
| A retention job destroys held records, or keeps excess metadata | Every deletion path re-checks event, actor, and policy holds immediately before writing, and the applier re-derives eligibility rather than trusting the plan. Deletion nulls the value columns only, keeping the provenance that documents the deletion |
| A fixed-duration job deletes regulated evidence before a host event such as liquidation starts the clock | Event-based rules exist for exactly this. A host calculation returning `nil` is reported as `unresolved`, never as due. See [the retention guide](retention-and-legal-holds.md#why-a-duration-alone-is-not-enough) |
| An external provider succeeds but the response is lost | The outbox path records `record_provider_outcome_unknown!` as a distinct state from success and failure, and reconciliation resolves it later. A timeout never becomes a fictional success or a second debit |

### The presentation and the surrounding page

| What happens if | What Clickwrap does |
|---|---|
| A custom view removes the real control, or moves the notice below the call to action | The development linter reports `submit_control_before_clickwrap_block`, `consent_control_preselected`, and `document_link_missing`. These are heuristics that warn; they never block a render and never certify a page. See [the accessibility guide](accessibility.md) |
| An analytics, notification, timestamp, or anchor call fails | After-commit work is an observer, never authorization. A failure is reported through `report_after_commit_failure_with` and cannot undo evidence and domain state that already committed. Timestamp/anchor attempts additionally record an immutable result when possible; the missing-attestation inventory and explicit reconciliation task cover a process or database failure in that post-commit window |
| An export leaks a document, actor detail, or request secret | Operator access requires a host authorization callback plus a plain-English reason, and every access appends a `ReceiptAccess` row. Foreign event IDs return not found, so existence is not leaked |

---

## What to tell an auditor

Say the tier, say its sentence, and say what is not in it.

At baseline, that is: canonical receipts, immutable document and statement snapshots while their
reviewed retention periods run, versioned SHA-256 digests, an append-oriented public API with
named disposition transitions, and a verifier that runs without this application. It detects
modification of the bytes it covers. It does not establish origin, does not establish time, and
does not exclude fabrication by a party controlling every source.

If you need stronger rewrite detection or a third party's statement about time, the mechanisms
are chained history, a verified publication of exact chain snapshots, and a timestamp or
trust-service provider — three separate things, each claiming only what it supplies.

`bin/rails clickwrap:doctor` reports objective configuration and data facts and never prints a
verdict. If it printed one, it would be the least trustworthy line in the output.

---

## Sources

| Source | Class |
|---|---|
| [NIST FIPS 180-4](https://csrc.nist.gov/pubs/fips/180-4/upd1/final) — SHA-2 hash standard | Technical standard |
| [RFC 3161](https://www.rfc-editor.org/info/rfc3161/) — time-stamp protocol | Technical standard |
| [Regulation (EU) No 910/2014 (eIDAS), Article 25](https://eur-lex.europa.eu/eli/reg/2014/910/2024-05-20/eng) — legal effect of electronic signatures | Law |
| [RFC 8785, JSON Canonicalization Scheme](https://www.rfc-editor.org/rfc/rfc8785) | Technical standard |
| [OWASP Logging Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html) | Industry guidance |
| [GDPR Article 32](https://eur-lex.europa.eu/eli/reg/2016/679/art_32/oj/eng) — security of processing | Law |
| The tier ladder and every "what Clickwrap does" cell above | Product-design inference |
