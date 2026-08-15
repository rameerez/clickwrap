# The public naming contract

Every public name must say what it contains and where it came from. The test is literal: a
15-year-old reading the initializer, a policy, an error message, a task's output, or a receipt
should not need to know internal abbreviations to understand what the application does.

This is not style. Clickwrap's value is evidence that is still true and still legible years
after it was written, and the names are part of the evidence. A field called `ua` in a receipt
from 2026 is a puzzle in 2031. A method called `dispose!` is a method nobody can review. An
option called `full` is a decision nobody can audit.

The rules below are normative for the whole gem — public methods, configuration settings, DSL
keywords, error messages, generated comments, task output, and receipt fields — not only for
request evidence.

---

## The eight rules

### 1. Prefer a complete verb plus noun

**Why:** a bare noun leaves the reader to guess the verb, and different readers guess
differently. "With ip" — with it how? Recorded? Filtered? Required?

```ruby
# Before
config.with_ip = true
policy.ip = :on

# After
config.record_ip_address_by_default = true
record_ip_address(because: "...", delete_after: 90.days)
```

### 2. Qualify the source

**Why:** "resolver" says something gets resolved. It does not say from what, which is exactly
the fact a reader needs in order to judge how much the value is worth. An address read from an
HTTP request and an address supplied by a client are different facts and must not share a name.

```ruby
# Before
config.ip_resolver = ->(x) { x.remote_ip }

# After
config.read_ip_address_from_http_request_with = ->(http_request) { http_request.remote_ip }
```

The same rule produces `read_browser_user_agent_from_http_request_with`, and it is why a
host-assigned reader is labeled `host_configured_reader` in the receipt rather than being
allowed to borrow the credibility of `rails_request_remote_ip`.

### 3. Positive booleans

**Why:** a negative boolean makes every reader do a double negative in their head, and
`disable_ip_capture = false` is a line that has been misread in every codebase that has ever
contained one.

```ruby
# Before
config.disable_ip_capture = false
config.no_geolocation = true

# After
config.record_ip_address_by_default = true
config.record_ip_geolocation_country_by_default = false
```

### 4. Destructive methods name exactly what they delete

**Why:** `dispose!` in a disposition report a year from now tells nobody which value went. Three
methods that each name one field mean the report, the audit event, and the log line all say
which category disappeared, rather than a euphemism covering several.

```ruby
# Before
Clickwrap.dispose!(receipt)
Clickwrap.purge_network_context!(receipt)
Clickwrap.delete_personal_data!(receipt)

# After
Clickwrap.delete_recorded_ip_address!(receipt, because: "Retention period ended")
Clickwrap.delete_recorded_browser_user_agent!(receipt, because: "Retention period ended")
Clickwrap.delete_recorded_ip_geolocation!(receipt, because: "Retention period ended")
```

The implementation may centralize disposal internally — it does. Public calls, task output,
audit events, and documentation keep the explicit field name.

Every destructive method also takes a plain-English `because:`. It is stored on the disposition
event and it is the only thing that will explain the deletion to somebody reading the record
years from now.

### 5. Distinguish configuration from fact

**Why:** "we are set up to record this" and "this was recorded" are different claims, and a
receipt that blurs them is worthless. The `_by_default` suffix marks a setting; the trailing
question mark marks an observation about one event.

```ruby
config.record_ip_address_by_default   # configuration: what we intend to do
receipt.recorded_ip_address?          # fact: what happened for this event
```

The same distinction runs through the six request-evidence states. `not_configured` is a
configuration fact; `unavailable` is an observation; `deleted_after_retention` is a third thing
entirely. None of them is blank.

### 6. One option never secretly enables another category of data

**Why:** this is the failure mode the gem exists to prevent. An option that turns on a category
of personal data as a side effect makes the diff unreviewable and the upgrade dangerous — a
later release can widen what the profile covers, and nobody reading the initializer would know.

```ruby
# Before
record_ip_geolocation(precision: :full)
record_request_context(level: :enhanced)

# After
record_ip_geolocation(
  country: true,
  region: true,
  city: true,
  postal_code: false,
  latitude_and_longitude: true,
  timezone: false,
  continent: false,
  metro_code: false,
  accuracy_radius_in_kilometers: true,
  because: "...",
  retain_until: :security_evidence_retention_ends
)
```

Nine fields, nine visible decisions, each with its own line in the privacy inventory.
`latitude_and_longitude` is one coupled choice on purpose: half a coordinate is not a result.

The installer follows the same rule. Interactive prompts ask about one category at a time, and
non-interactive installs use individual flags such as
`--record-ip-addresses-by-default`. The sole recipe,
`--request-evidence-recipe=privacy-minimized`, writes every collection setting explicitly as
`false`; it can never enable a data category. There is no `evidence-rich`, `full`, or other named
recipe whose expansion could collect more in a later release.

### 7. No unexplained acronyms or abbreviations

**Why:** an abbreviation is a shared secret between the author and whoever was in the room. A
receipt is read by people who were not.

```ruby
# Before
receipt.ua
receipt.geo
event.addr
capture!(:signup, ctx: request)

# After
receipt.browser_user_agent
receipt.ip_geolocation_country_code
receipt.ip_address
Clickwrap.capture!(:signup, http_request: request)
```

Two abbreviations are permitted because they are the standards' own names and expanding them
would be less clear, not more: `ip` inside `ip_address` and `ip_geolocation`, and `http` inside
`http_request`.

### 8. Every example must make sense read aloud

**Why:** it is the cheapest review anyone can run, and it catches almost everything the other
seven rules are trying to prevent.

Read this aloud:

> Clickwrap capture and, withdrawal authorization, actor current user, subject withdrawal, http
> request request, submission clickwrap submission.

It is a sentence. Now read the alternative:

> Clickwrap capture, with ip, ctx request, full.

If an example does not survive being read aloud by a developer who has never seen the gem, the
name is wrong. Fix the name, not the example.

---

## Required vocabulary

Use the left column. The right column is what has been rejected and why.

| Use | Not | Because |
|---|---|---|
| `ip_address` | `ip`, `remote_address`, `network_address`, `addr` | Abbreviations, and "network address" hides which address |
| `ip_geolocation` | `geo`, `location`, `coordinates` | "Location" reads as where the person is. It is an estimate about an address |
| `ip_geolocation_latitude_and_longitude` | `precise_location`, `fine_location` | "Precise" is the opposite of true here |
| `ip_geolocation_accuracy_radius_in_kilometers` | `accuracy` | A number with no unit and no meaning |
| `ip_geolocation_provider_name`, `ip_geolocation_provider_source`, `ip_geolocation_database_version` | `provider`, `source` | In a receipt, "source" could mean four things |
| `browser_user_agent` | `ua`, `client_info`, `browser` | The raw header is a specific thing; "browser" suggests a parsed result |
| `http_request` | `context`, `ctx`, `env` | "Context" is where unreviewed data goes to hide |
| `capture_channel` | `flow`, `source` | Unqualified nouns again |
| `authentication_method` | `assurance` | Assurance supplied by whom, measured how? |
| `recorded_at_by_server` | `signed_at`, `timestamped_at` | Nothing signed it. It is the application server's own clock, and the name has to keep saying so |
| `estimated`, `client_supplied`, `server_observed`, `provider_reported` | dropping the qualifier | These four words are the difference between a fact and an overclaim |

## Booleans read as questions

```ruby
receipt.recorded_ip_address?
receipt.recorded_browser_user_agent?
receipt.recorded_ip_geolocation_country?
receipt.recorded_ip_geolocation_city?
receipt.recorded_ip_geolocation_latitude_and_longitude?
receipt.ip_geolocation_was_estimated?
receipt.ip_geolocation_source_was_verified_by_host?
receipt.ip_address_was_deleted?
receipt.browser_user_agent_was_deleted?
```

The `was_` prefix on the last four is doing work: `ip_geolocation_was_estimated?` is a statement
about the value that was stored, not about the resolver's current settings, and
`ip_address_was_deleted?` is a fact about this record rather than about policy.

The same grammar runs through the actor proxy, which is where most application code meets the
gem:

```ruby
user.clickwraps.agreed_to?(:terms)
user.clickwraps.acknowledged?(:privacy_notice)
user.clickwraps.consented_to?(:product_updates)
user.clickwraps.declared?(:non_professional_driver, subject: scheme)
user.clickwraps.attested?(:bank_accepted_transfer)
user.clickwraps.authorized?(:withdrawal, subject: withdrawal)
user.clickwraps.exempted_from?(:signup)
```

Six kinds, six predicates. There is no generic `accepted?`, because collapsing them would erase
the distinction the six kinds exist to preserve — and `exempted_from?` is separate precisely so
an exemption can never answer a human-action question.

---

## Prohibited option names

These may not appear as public options, keywords, settings, or command-line flags. Each one is
banned for a specific reason, not for taste.

| Never | Why |
|---|---|
| `:network`, `:full`, `:enhanced`, `:forensic`, `:maximum` | They hide what will be collected behind a word that sounds like a quality level |
| `record_location` | A developer could reasonably read it as GPS or physical location. It is neither |
| `request_evidence: :network`, `track_everything`, `record_everything` | Category switches. See rule 6 |
| `maximum_evidence`, `full_evidence`, `legal_proof: true` | They imply a verdict the gem cannot reach, and they enable data as a side effect |
| An opaque privacy-profile switch keyed to a regulation | No runtime flag can make a legal determination on anyone's behalf, and the name would be the least accurate string in the codebase |
| `include_sensitive_context: true` | One flag turning on three categories of personal data makes an operator's intent unreviewable. Use `include_ip_address:`, `include_browser_user_agent:`, `include_ip_geolocation:` |
| `dispose!`, `purge!`, `cleanup!` as public API | See rule 4 |

There is also no `--gdpr-*`, `--record-network-context`, `--record-everything`, or
`--full-evidence` generator flag. Non-interactive installer options are as explicit as the
settings they write:

```text
--record-ip-addresses-by-default
--record-ip-geolocation-cities-by-default
--record-ip-geolocation-latitude-and-longitude-by-default
--delete-recorded-ip-addresses-after-days=90
```

---

## The same standard for the rest of the initializer

The rule is not a request-evidence rule. It produced the shape of the whole configuration
object.

| Shipped name | Rejected | Why |
|---|---|---|
| `actor_class_name` | `actor_class` | It holds a string, constantized lazily so the initializer works before the model loads. The name says which |
| `current_actor_method_name` | `current_actor` | It is a method name, not an actor |
| `find_current_tenant_with` | `tenant_resolver` | Verb plus source. It is a callable that finds something |
| `store_document_contents_in` | `document_store` | Says what goes where |
| `digest_canonical_receipts_with` | `integrity` | "Integrity" is a category, not a decision. This one names the algorithm's job |
| `chain_event_history_with`, `anchor_event_history_with`, `timestamp_receipts_with` | one `integrity_level` setting | Three different mechanisms making three different claims. One setting would let a reader infer the strongest from the presence of the weakest |
| `after_event_is_committed` | `after_commit` | Says which commit, and reads as a sentence |
| `authorize_unredacted_request_evidence_access_with` | `access_control` | Long, and correct. It names exactly which access it authorizes |
| `deliberately_store_request_evidence_unencrypted!(because:)` | `encryption: false` | Turning encryption off should be a sentence a reviewer can find in a diff, with the host's own reason attached — not a `false` |

The last row is the pattern worth copying. When an option has a consequence somebody should
have to think about, make the name carry the thinking.

---

## Reviewing a new name

Before you add a public method, option, setting, or receipt field:

- [ ] Read the example aloud. Does it parse as English?
- [ ] Does the name say what it contains **and** where it came from?
- [ ] Is the boolean positive?
- [ ] If it deletes something, does the name say which thing?
- [ ] Does it distinguish "we are configured to" from "this happened"?
- [ ] Could enabling it turn on a category of personal data the reader did not name?
- [ ] Are there abbreviations that are not `ip` or `http`?
- [ ] If it goes into a receipt: will it still be legible in 2031, to somebody who has never
      seen this codebase?
- [ ] If it goes into a receipt: is it in `Clickwrap::Vocabulary`? Stable strings live there,
      frozen, in one place, and they are **added to, never renamed or repurposed** — a value
      that changed meaning underneath an old receipt would make it say something it never said.

A name that fails any of these is cheaper to change now than after the first release, because
after the first release it is in receipts.

---

## Sources

| Source | Class |
|---|---|
| `docs/strategy/02-request-evidence.md`, "Public naming rules" — the normative source for this guide | Internal normative design document |
| Every rule, rejection, and rationale above | Product-design inference |
