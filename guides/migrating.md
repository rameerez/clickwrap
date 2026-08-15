# Migrating without inventing history

Importing is the single easiest place in this gem to manufacture evidence by accident. Every
field a modern capture fills in is sitting right there with an obvious, plausible value: the
current Terms text, today's document digest, the submit-button label from the current view, the
assertion sentence from the current policy, an IP address from the user's last session.

Writing any of them produces a row that is **indistinguishable from a real capture** and is, in
the parts that matter, a fabrication. Nobody reading the receipt in a dispute three years from
now would be able to tell.

So the governing rule for every import path is: historical weakness stays visible rather than
being laundered into modern certainty. An honest gap is worth more than a confident invention,
because the gap is a fact about the evidence and the invention is a lie about it.

---

## What is never synthesized

| Field | Why it cannot be filled in |
|---|---|
| The presentation manifest | Nobody signed one. There is no offer to reproduce, and a synthesized manifest would be a signed description of an offer nobody made |
| The assertion | The sentence the person was actually shown was not recorded. Using the current policy's wording would claim they saw text that may not have existed yet |
| Submit-button text | The words on the control were not recorded |
| IP address, browser user-agent, IP geolocation | These were never observed by this application. A later session's address is a different fact about a different request |
| Document bytes and digests | Only linked when the caller can point at a version that is **actually published here**. A version label alone is a claim about a label, not about content |
| The protected action | The old system did not bind evidence to an outcome |

Every key you list in `unknown:` is recorded twice: as a structured field on the event, and in
plain words inside the assertion text of each statement — which is inside the digested canonical
body, so the admission travels *with* the evidence rather than beside it where it can be lost.

Two more things the importer keeps apart on purpose:

- **`occurred_at` and `recorded_at_by_server`.** The first is when the old record says it
  happened; the second is when this row was written. Collapsing them would quietly upgrade a
  migration into a contemporaneous observation. The distance between the two is itself evidence.
- **Attribution.** An imported event records `imported_provider`, never `authenticated_session`
  and never `unknown`. "This reached us from somewhere else" is a different fact from "we do not
  know how they were attributed."

An import can never claim `web_browser` as its capture channel. The permitted values are
`imported_provider` and `system`, because no browser was involved and a receipt saying otherwise
would be wrong.

---

## From `accepted_terms_at`

The typical starting point is a boolean or a timestamp column and a version string.

### Step 1: dry run one record

Always. `dry_run: true` reads everything, writes nothing, and returns the same `Result` shape as
the real thing, so your migration script reads identically either way.

```ruby
user = User.find(1)

result = Clickwrap.import_legacy!(
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
  because: "Imported from users.accepted_terms_at",
  source: "users.accepted_terms_at",
  dry_run: true
)

result.planned?         # => true
result.written?         # => false
result.message
# => "Would import terms for gid://my-app/User/1 (terms). Not recorded by the source and
#     therefore unknown: assertion, exact_document_bytes, presentation, request_evidence,
#     submit_button_text."
result.idempotency_key  # => "imported_legacy:9f86d0…"
```

Read that message before you read anything else. It is the sentence that will end up in the
receipt, and if it does not describe your legacy data accurately, your `unknown:` list is wrong.

### Step 2: check the batch shape

Run the dry run across a sample and look at three things:

```ruby
sample = User.where.not(accepted_terms_at: nil).limit(500)

results = sample.map do |user|
  Clickwrap.import_legacy!(:terms, actor: user, occurred_at: user.accepted_terms_at,
                           known: { document_version: user.terms_version },
                           unknown: %i[exact_document_bytes presentation assertion
                                       submit_button_text request_evidence],
                           because: "Imported from users.accepted_terms_at",
                           dry_run: true)
end

results.count(&:planned?)
results.group_by { |r| r.known["document_version"] }.transform_values(&:size)
results.map(&:idempotency_key).uniq.size == results.size
```

- **How many are planned.** A record with no `occurred_at` raises rather than importing, because
  Clickwrap will not substitute the time of the import. If the legacy row genuinely has no time,
  do not import it as an act — record an exemption with `Clickwrap.exempt!` instead.
- **Which version labels appear.** Any label that is not a published Clickwrap document version
  will import as a label with no document bytes attached. That may be fine; it should not be a
  surprise.
- **That the idempotency keys are unique.** The key is derived from the policy, actor, subject,
  tenant, `occurred_at`, and every `known:` value, so re-running the same script over the same
  rows is a no-op rather than a second history for the same person. Change any of those inputs
  and it is a different import — which is correct, since a different claim deserves a different
  event rather than silently colliding with the first.

### Step 3: import for real

Drop `dry_run: true`.

```ruby
User.where.not(accepted_terms_at: nil).find_each do |user|
  result = Clickwrap.import_legacy!(
    :terms,
    actor: user,
    occurred_at: user.accepted_terms_at,
    known: { document_version: user.terms_version },
    unknown: %i[exact_document_bytes presentation assertion submit_button_text request_evidence],
    because: "Imported from users.accepted_terms_at",
    source: "users.accepted_terms_at"
  )

  Rails.logger.info(result.message)
end
```

Re-running it is safe: an already-imported record returns `status: :already_imported` and writes
nothing.

### What the imported receipt looks like

The assertion says, in the receipt, exactly what this is:

> Imported from a pre-existing record: it states that this actor agreed to terms on
> 2023-04-11T08:22:07.000000Z. The original wording shown to them was not recorded, so this is
> not the sentence they saw. Not recorded by the source and therefore unknown: assertion,
> exact_document_bytes, presentation, request_evidence, submit_button_text. Imported from
> users.accepted_terms_at.

And the provenance block carries the structured version, including a `not_collected` list naming
`presentation_manifest`, `ip_address`, `browser_user_agent`, and `ip_geolocation`, plus a
`means` sentence saying Clickwrap did not present this content and did not observe this action.

The statement itself records `answered: false` and `answer: nil`. The action says what the old
system claims happened; `answered` records whether *we* have the answer, and we do not.

### Conventional `unknown:` keys

The vocabulary is open — name anything your source did not record — but these are the keys the
importers use, so a typo in a migration script is at least visibly a typo next to its
neighbours:

`exact_document_bytes`, `document_version`, `presentation`, `presentation_manifest`,
`assertion`, `submit_button_text`, `protected_action`, `request_evidence`, `ip_address`,
`browser_user_agent`, `capture_channel`, `authentication_context`.

Listing `exact_document_bytes` or `document_version` in `unknown:` also stops the importer from
attaching any document version at all, even if `known["document_version"]` is present. Saying
"we do not know the bytes" and then linking bytes anyway would contradict itself.

### Optional statements are excluded by default

If the policy has optional consent statements, `import_legacy!` imports only the **required**
ones unless you name statements explicitly:

```ruby
Clickwrap.import_legacy!(:signup, ..., statements: %i[terms privacy_notice])
```

A legacy boolean column recorded one decision. Reading it as a grant of an optional consent
purpose it never mentioned would invent the exact thing an optional control exists to keep
honest.

---

## From FinePrint

[FinePrint](https://github.com/openstax/fine_print/blob/3b75fbcbcfb048ecd2f4ee7c4f0b9bd3d10f7603/README.md#L7-L25)
*(pinned source code)* is established Rails prior art for versioned contracts, signatures,
gates, and views. This importer exists because applications outgrow a question, not because they
chose badly. FinePrint answers "did user U sign version N of contract X?", and it answers it
well. What it never tried to record — the presentation, the exact wording beside the control,
the call to action, the request context, the domain action the signature authorized — comes
across as `unknown`.

The importer deliberately does **not** depend on the `fine_print` gem, require any of its files,
or reference any of its constants. It reads two tables through your own connection, if they are
there, and discovers columns rather than assuming them. A migration tool that forces you to keep
the gem you are migrating away from installed is a migration tool with a hostage.

### Plan first

```ruby
report = Clickwrap::Import::FinePrint.plan(
  policy_key: :signup,
  find_actor_with: ->(user_type, user_id) { User.find_by(id: user_id) },
  map_contract_with: ->(contract) { contract["name"] == "terms_of_use" ? :terms : nil },
  because: "Migrating from FinePrint"
)

report.possible?    # => false when the tables are not in this database
report.signatures   # => how many rows would be imported
report.planned      # => the per-signature results
report.contracts    # => one ContractMapping per FinePrint contract version
report.message
```

`report.contracts` is the part to read carefully. Each `ContractMapping` reports the FinePrint
contract name and version, the Clickwrap document key you mapped it to, and — crucially —
`published?`: whether a matching Clickwrap document version actually exists here. That is what
decides whether an imported event can carry real document bytes or must record the label alone.
The summary message names every contract that has no published match.

Two callbacks are yours to supply:

- **`find_actor_with`** receives `(user_type, user_id)` and returns the actor record, a stable
  actor reference string, or `nil` to skip that signature.
- **`map_contract_with`** receives a contract row as a plain hash and returns the Clickwrap
  document key it corresponds to. Only your application knows that its FinePrint contract named
  `"terms_of_use"` is the document this gem calls `:terms`. Omit it and the contract's `name`
  column is used as the key.

`contract_names:` narrows to specific contracts and `limit:` caps the number of signatures —
both useful for a staged migration.

If the tables are not present, the report says so in a sentence and writes nothing, rather than
raising. That keeps `clickwrap:doctor` and a migration checklist runnable on an application
that never used FinePrint.

### Then import

```ruby
report = Clickwrap::Import::FinePrint.import!(
  policy_key: :signup,
  find_actor_with: ->(_user_type, user_id) { User.find_by(id: user_id) },
  map_contract_with: ->(contract) { contract["name"] == "terms_of_use" ? :terms : nil },
  because: "Migrating from FinePrint"
)

report.imported.size
report.already_imported.size
```

Each signature becomes an `imported_legacy` event through the same path as
`Clickwrap.import_legacy!`, so it inherits every property above: idempotency, the two separate
times, the explicit unknowns, and the assertion text that says the original wording was not
recorded.

### What FinePrint knew and what it did not

| Recorded as `known` | Recorded as `unknown` |
|---|---|
| `source_system: "fine_print"` | `exact_document_bytes` |
| `fine_print_signature_id` | `presentation_manifest` |
| `fine_print_contract_id` | `assertion` |
| `contract_name`, `contract_title` | `submit_button_text` |
| `fine_print_contract_version` | `protected_action` |
| `signed_by_type`, `signed_by_id` | `request_evidence`, `ip_address`, `browser_user_agent` |

Note the deliberate naming: the version arrives as **`fine_print_contract_version`**, not
`document_version`. The `document_version` key is what makes the legacy importer link published
bytes, and a FinePrint version number is a label in another system's numbering — not a claim
about which bytes this application published. If you want the bytes linked, publish the matching
Clickwrap document version and pass `document_version` yourself.

`occurred_at` comes from the signature row's `created_at` (falling back to `updated_at`). That is
the best time available, and like every import it stays separate from when the Clickwrap event
was written down.

---

## After the import

Verify what you actually got, rather than assuming:

```ruby
receipt = user.clickwraps.receipts.last

receipt.event.event_type          # => "imported_legacy"
receipt.to_h["actor"]["attribution"]["method"]   # => "imported_provider"
receipt.to_h["request_evidence"]  # => every category "not_configured"
receipt.verify.success?
```

And run the ordinary health check:

```bash
bin/rails clickwrap:doctor
bin/rails clickwrap:verify
```

An imported event will not satisfy `agreed_to?` in the way a live capture does — imports are not
in the human-action event types. If your gate needs imported history to count, that is a policy
decision to make explicitly rather than one to discover from a failing predicate in production.

---

## Sources

| Source | Class |
|---|---|
| [FinePrint README at the audited commit](https://github.com/openstax/fine_print/blob/3b75fbcbcfb048ecd2f4ee7c4f0b9bd3d10f7603/README.md#L7-L25) | Pinned source code |
| [FinePrint signature model at the audited commit](https://github.com/openstax/fine_print/blob/3b75fbcbcfb048ecd2f4ee7c4f0b9bd3d10f7603/app/models/fine_print/signature.rb#L1-L33) | Pinned source code |
| `lib/clickwrap/import/legacy.rb`, `lib/clickwrap/import/fine_print.rb`, `lib/clickwrap/vocabulary.rb` at commit `a1ffe9b` | Pinned source code |
| The never-synthesize rule, the `unknown:` vocabulary, and the dry-run-first workflow | Product-design inference |
