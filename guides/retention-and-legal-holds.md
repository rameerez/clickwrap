# Retention, disposition, and legal holds

Clickwrap does not choose retention periods and cannot tell you whether yours are right. What
it does is make a reviewed decision executable and auditable, keep the core event's schedule
separate from the optional personal request evidence attached to it, and support the
event-based rules that real record-keeping obligations actually use.

Every policy names a retention class. There is no default or fallback for captured payloads or
optional request evidence, and Clickwrap never picks a period. After a reviewed core disposition,
a minimal row and its digest-linked disposition successor remain without another disposal
schedule. Those tombstones document the deletion itself and are deliberately excluded from
future disposition plans; recursively deleting the proof of deletion would recreate the hole
the tombstone exists to prevent.

---

## Two vocabularies, because they are two intentions

```ruby
Clickwrap.retention :ordinary_agreement_evidence do
  retain_core_event_for 6.years
  delete_recorded_ip_address_after 90.days
  delete_recorded_browser_user_agent_after 90.days
  delete_recorded_ip_geolocation_after 90.days
end
```

`retain_..._for` and `retain_..._until` say how long evidence is kept. `delete_..._after` says
when personal request evidence goes away. They read differently on purpose: the second one is
the destructive one, and a reviewer scanning a diff should be able to see which is which
without parsing the noun.

| Part | Duration rule | Event-based rule |
|---|---|---|
| The core event | `retain_core_event_for 6.years` | `retain_core_event_until :your_host_event` |
| Recorded IP address | `delete_recorded_ip_address_after 90.days` | `retain_recorded_ip_address_until :your_host_event` |
| Recorded browser user-agent | `delete_recorded_browser_user_agent_after 90.days` | `retain_recorded_browser_user_agent_until :your_host_event` |
| Recorded IP geolocation | `delete_recorded_ip_geolocation_after 90.days` | `retain_recorded_ip_geolocation_until :your_host_event` |

A retention class that never says how long to keep the core event raises a `DefinitionError` at
boot, naming both forms. A rule whose duration is zero or negative raises too. Clickwrap will
not pick a payload-retention period for you.

---

## Why a duration alone is not enough

Take a real pair of obligations, both from Spanish law:

- The reviewed TRA040 v2 shared-mobility publication requires at least five years of
  platform-data retention, alongside verifiable evidence that each user received a
  versioned and date-stamped data-sharing notice
  ([official BOE PDF](https://www.boe.es/boe/dias/2026/08/04/pdfs/BOE-A-2026-16993.pdf)) *(law)*.
- Order TED/815/2023 separately requires submitted documents to be retained until at least
  three years after **liquidation**
  ([Article 14.12](https://www.boe.es/eli/es/o/2023/07/18/ted815)) *(law)*.

Put together, the schedule for one record is: **five years from capture, or three years after
liquidation, whichever is later.**

A duration cannot express that. At capture time, liquidation has not happened; there is no date
to add three years to, and no way to know whether the resulting date will land before or after
the five-year mark. Encoding it as `6.years` would be a guess that is wrong in both directions
— too short when liquidation is late, and needlessly long when it is early. Encoding it as
"delete after five years" destroys regulated evidence early in exactly the cases that matter.

So the rule names a host calculation instead:

```ruby
Clickwrap.retention :regulated_evidence do
  retain_core_event_until :regulated_evidence_retention_ends
  retain_recorded_ip_address_until :security_evidence_retention_ends
  retain_recorded_browser_user_agent_until :security_evidence_retention_ends
  retain_recorded_ip_geolocation_until :security_evidence_retention_ends
end
```

```ruby
Clickwrap.configure do |config|
  config.calculate_retention_time_for :regulated_evidence_retention_ends do |event|
    [
      event.recorded_at_by_server + 5.years,
      event.subject.respond_to?(:liquidated_at) ? event.subject.liquidated_at&.+(3.years) : nil
    ].compact.max
  end

  config.calculate_retention_time_for :security_evidence_retention_ends do |event|
    event.recorded_at_by_server + 2.years
  end
end
```

**Returning `nil` is a legitimate answer.** It means the triggering event has not happened yet,
so the clock has not started. The planner reports that item as `unresolved` — a third category
alongside `due` and `held` — rather than inventing a date or treating "we cannot say yet" as
"delete it now." That failure mode is specific and foreseeable, and it is the reason the report
has three columns instead of two.

Three ways a host calculation can fail to produce a date, all reported as `unresolved` with the
reason attached rather than crashing the run: it returns `nil`, it is not registered, or it
raises. A disposition run that dies on one row, or that guesses a date to keep going, is worse
than one that says which rows it could not evaluate.

Note which schedules the planner reads: **the ones recorded on each row when that row was
created**, not today's policy. The capture event, a later withdrawal, and a still-later expiry
each freeze their own core schedule. The annex freezes each enabled category's schedule. Changing
a policy changes future events; it does not silently reschedule records already written.

Linked events age independently. Disposing of a root event does not cascade to a retained
withdrawal, expiry, consumption, correction, or other successor. A current-state projection is
removed only when the exact event it points at is disposed of. This prevents an older root's
deadline from erasing a newer lifecycle fact early.

The deadline boundary is inclusive: an item is due when its recorded or resolved deadline is
less than or equal to the planner's `at` time. It does not wait for a later clock tick.

---

## Plan, then apply

Disposition is always two steps.

```bash
bin/rails clickwrap:retention:plan
```

```text
Disposition plan 01K2Y8T5QY0N4V6N1H4G4CQY8J
  due:        4182
  held:       12 (a legal hold is pausing these)
  unresolved: 305 (a host event has not happened yet)
```

The plan deletes nothing, marks nothing, and changes no state anywhere else. An operator can
run it on a Friday afternoon without consequence. It can be narrowed with `POLICY=`, `ACTOR=`,
`BY=`, and `BECAUSE=`, and it covers five parts: the four parts of an event plus persisted
presentations, which are not evidence of an act and age out on their own schedule.

Held items are counted separately rather than dropped, so an operator who expected four
thousand items and sees twelve can tell that a hold is working rather than that the query is
broken.

```bash
bin/rails clickwrap:retention:apply PLAN=01K2Y8T5QY0N4V6N1H4G4CQY8J
```

### Why apply re-checks

The applier does not trust the plan. It re-derives every item's eligibility and re-checks every
hold, and it reports skips in two named buckets — `skipped_held` and `skipped_changed` — rather
than one. The reasons it can refuse:

| Condition | What happens |
|---|---|
| A legal hold was placed after the plan was built | The item is skipped and recorded as held. The hold wins even if it lands between the check and the write |
| The retention class changed, or is gone | The item is skipped as changed |
| The item is no longer due — a host calculation now returns a later date, or none | Skipped as changed |
| The record was already deleted, or no longer exists | Skipped as changed |
| The plan expired | The whole run refuses. Plans live 24 hours by default |
| The plan was already applied, or superseded by a newer one | The whole run refuses, naming which |
| A worker died after claiming the plan | The plan stays claimed. Recovery requires an explicit stale duration, a new operator reference, and a plain-English recovery reason; every item is rechecked, so already-committed dispositions are reported rather than repeated |

Each refusal names its specific reason, so an operator sees "the plan expired" or "this was
already applied" rather than a generic decline. The run exits non-zero if anything was skipped
or errored, so a scheduled job cannot quietly do less than it reported.

The point of the two-step is not ceremony. It is that the set an operator reviewed and the set
that gets deleted must be the same set, and between the review and the click, someone may have
placed a hold.

### Deleting one field directly

```ruby
Clickwrap.delete_recorded_ip_address!(receipt, because: "Retention period ended")
Clickwrap.delete_recorded_browser_user_agent!(receipt, because: "Retention period ended")
Clickwrap.delete_recorded_ip_geolocation!(receipt, because: "Retention period ended")
```

Three methods, one per field, each naming exactly what it removes. There is deliberately no
`delete_personal_data!`, no `purge_network_context!`, and no method that takes out three
categories at once: someone reading a disposition report a year from now has to be able to see
which value disappeared, not a euphemism covering several. Each requires a plain-English
`because:`, refuses while a hold is in effect, and appends its own `disposition` event.

Deleting a field that was never recorded, or was already deleted, is a no-op that appends no
event — an event saying "deleted" where nothing was ever recorded would be false.

---

## What deletion changes about a receipt, and what it does not

Deleting the recorded IP address does **not**:

- rewrite the historical agreement, declaration, or authorization;
- touch any column of the core event;
- change the event's `request_evidence_digest`;
- make a previously verifying event stop verifying.

The event's canonical body excludes every annex value on purpose. That is the entire reason the
annex is a separate table. An ordinary retention run cannot make a verified event fail
verification, because deletion changes what a receipt can *show*, never what it *says
happened*.

What it does change:

| Before | After |
|---|---|
| `{"state": "recorded"}`, or `{"state": "redacted_for_this_viewer"}` for an unauthorized reader | `{"state": "deleted_after_retention", "deleted_at": "2026-11-13T09:00:00.000000Z"}` |
| The value column holds the value | The value column is `nil` |
| — | A linked `disposition` event carries the field name, the reason, and who ran it |

Provenance survives deliberately. The reader name, the trusted-proxy configuration digest, the
recorded-at timestamp, the provider name, the database version, the accuracy metadata, and the
rule the deletion ran under all stay. Erasing them too would turn a documented deletion into a
gap, which is the one outcome a retention process must never produce.

One consequence is worth stating rather than discovering: the keyed binding digest recorded at
capture stays as written, and after deletion it no longer recomputes from the annex. That is
the expected result of a permitted deletion, not a sign of interference, and the receipt says
which by reporting the field as `deleted_after_retention` with its timestamp.

**Disposing of the core event** is deliberately different from deleting one annex value. In one
transaction Clickwrap appends a digest-checked `disposition` successor, records its ID and time
on the original row, clears the fixed core payload and statement/document bindings, and leaves
the original row at its chain position. The original digest can no longer be re-derived from a
payload that was intentionally removed, so verification reports a
`documented_core_disposition` separately from an ordinary verifying digest. A bare disposition
marker, a lookalike event, a wrong predecessor/root link, or mismatched original digest fails
closed as an integrity error. The surrounding chain can still be walked using the retained
original digest and the linked successor.

One operational boundary follows from intentional deletion: current state can be rebuilt from
retained event payloads, but not from personal statement identity that a reviewed root
disposition removed. `CurrentState.rebuild_for!` refuses before deleting an existing projection
when it can see that dependency. Do not drop `clickwrap_statement_states` after core disposition
has begun and expect disposed identity facts to reappear; that would defeat the disposition.

A retained digest is described as a **retained linkable digest**, never automatically called
anonymous. The binding digest is keyed rather than a plain hash for a concrete reason: an IPv4
address is 32 bits ([RFC 791](https://www.rfc-editor.org/info/rfc791/)) *(technical standard)*,
so an unsalted hash of one can be tested by enumerating every address in minutes. Even keyed,
treat the result as pseudonymous data that outlives the value it covers, and analyze it that
way under your own privacy model.

---

## Legal holds

```ruby
receipt.place_on_legal_hold!(
  because: "Pending dispute 2026-184",
  placed_by: current_operator,
  review_at: 6.months.from_now
)

receipt.release_legal_hold!(
  because: "Dispute resolved",
  released_by: current_operator
)
```

All three arguments are required, and each one is load-bearing:

- **`because:`** — an indefinite hold nobody can explain is indistinguishable from a bug.
- **`placed_by:`** — a hold with no owner has nobody to ask about it.
- **`review_at:`** — a hold nobody revisits is exactly how "we'll delete it later" becomes "we
  kept everything forever." A retention policy that can be suspended invisibly is not a
  retention policy.

Hold history uses named append transitions. Placing one appends a `legal_hold_placed` event;
releasing one appends a `legal_hold_released` event and records who released it and why. They
come in three scopes — `event`, `actor`, and `policy` — and all three are checked before any
deletion. A hold on an actor's whole file is not weaker than one on a single receipt.

```bash
bin/rails clickwrap:holds:review
```

lists every hold in effect and, separately, the ones past their review date.

---

## Actor deletion does not cascade

`has_clickwraps` deliberately does not add a `dependent: :destroy`. Deleting an account must not
silently erase the record of what that person agreed to — that is a retention decision, and it
belongs to you rather than to a foreign key.

Instead: the installer generates restrictive or nullifying relationships, the association
nullifies the actor link, and the evidence keeps the stable pseudonymous reference produced by
`config.identify_actor_with` (a model override, GlobalID when available, or a stable class/id
fallback). What happens next is whatever your
retention policy says.

For an erasure request, the tooling produces a reviewable plan rather than a verdict:

```bash
bin/rails clickwrap:privacy:disposition:plan ACTOR=gid://my-app/User/123
```

```ruby
Clickwrap::Privacy.plan_disposition_for(
  actor,
  requested_by: current_operator,
  because: "Verified erasure request DSAR-2026-41"
)
```

The plan shows what would happen. It does not decide whether an erasure request overrides a
retention duty, a legal claim, or a hold. That decision is yours, and the plan is what you make
it with.

---

## A worked example, end to end

A regulated payout authorization: five years or three years after liquidation, whichever is
later, for the core event; two years for the request evidence.

**1. Declare the retention class and register the calculations.**

```ruby
# config/clickwrap.rb
Clickwrap.retention :regulated_evidence do
  retain_core_event_until :regulated_evidence_retention_ends
  retain_recorded_ip_address_until :security_evidence_retention_ends
  retain_recorded_browser_user_agent_until :security_evidence_retention_ends
  retain_recorded_ip_geolocation_until :security_evidence_retention_ends
end

Clickwrap.configure do |config|
  config.calculate_retention_time_for :regulated_evidence_retention_ends do |event|
    [
      event.recorded_at_by_server + 5.years,
      event.subject.respond_to?(:liquidated_at) ? event.subject.liquidated_at&.+(3.years) : nil
    ].compact.max
  end

  config.calculate_retention_time_for :security_evidence_retention_ends do |event|
    event.recorded_at_by_server + 2.years
  end
end
```

**2. Point the policy at it.**

```ruby
Clickwrap.policy :regulated_authorization do
  authorize :regulated_action, one_time: true, valid_for: 10.minutes

  review_request_evidence_configuration_on Date.new(2027, 8, 15)

  record_ip_address(
    encrypted: true,
    retain_until: :security_evidence_retention_ends,
    because: "Investigate account compromise and disputes about this action",
    legal_basis_reference: "LIA-SECURITY-2026-01"
  )

  retain_with :regulated_evidence
end
```

**3. Capture. The schedule is written onto the row.** The annex gets
`ip_address_retain_until_rule = "security_evidence_retention_ends"`. The event gets its
retention class and, where the rule resolves at capture, a computed
`retain_core_event_until`.

**4. Two years pass. Run the plan.**

```bash
bin/rails clickwrap:retention:plan POLICY=regulated_authorization BY=ops@example.com
```

The IP address is `due`. The core event is `unresolved` — the calculation returns
`recorded_at + 5.years`, which has not arrived — so it is not offered for deletion at all.

**5. Someone opens a dispute. Place a hold before applying.**

```ruby
Clickwrap.receipt(event_id).place_on_legal_hold!(
  because: "Pending dispute 2026-184",
  placed_by: current_operator,
  review_at: 6.months.from_now
)
```

**6. Apply the plan anyway.**

```bash
bin/rails clickwrap:retention:apply PLAN=01K2Y8T5QY0N4V6N1H4G4CQY8J
```

That item lands in `skipped_held` with the note naming the event, and the task exits non-zero.
The hold was placed after the plan was built and it still wins, because the applier re-checks
rather than trusting the plan. Nothing was deleted for that event.

**7. The dispute resolves.**

```ruby
receipt.release_legal_hold!(because: "Dispute resolved", released_by: current_operator)
```

**8. Plan and apply again.** This time the IP address is deleted. The receipt now reports:

```json
"request_evidence": {
  "ip_address": {
    "state": "deleted_after_retention",
    "deleted_at": "2028-09-02T11:04:31.882410Z"
  },
  "browser_user_agent": { "state": "not_configured" },
  "ip_geolocation": { "state": "not_configured" }
}
```

A `disposition` event now hangs off the original, carrying the field name and the reason. The
authorization itself is untouched: same statements, same documents, same digests, still
verifying.

**9. Three years later, or three years after liquidation — whichever the calculation returns —**
the core event becomes due, and the same two-step disposes of it. `core_event_disposed_at` is
set, another `disposition` event explains it, and the row stays where an auditor can find it.

---

## Sources

| Source | Class |
|---|---|
| [TRA040 v2, official BOE PDF](https://www.boe.es/boe/dias/2026/08/04/pdfs/BOE-A-2026-16993.pdf) — at least five years of platform-data retention | Law |
| [Order TED/815/2023, Article 14.12](https://www.boe.es/eli/es/o/2023/07/18/ted815) — retention until at least three years after liquidation | Law |
| [GDPR Article 5](https://eur-lex.europa.eu/eli/reg/2016/679/art_5/oj/eng) (storage limitation), [Article 17](https://eur-lex.europa.eu/eli/reg/2016/679/art_17/oj/eng) (erasure, with its exceptions including legal claims) | Law |
| [RFC 791](https://www.rfc-editor.org/info/rfc791/) — IPv4 addresses are 32 bits | Technical standard |
| The plan/apply split, the three-category report, and the hold requirements | Product-design inference |

The periods in every example above are placeholders. Clickwrap does not know your jurisdiction,
your sector, or your obligations, and nothing here is a recommendation about any of them.
