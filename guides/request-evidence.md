# Request evidence: the data dictionary

Clickwrap always records the event ID, the server-recorded time, the capture channel, the
configured actor and authentication source, the policy and application version, and the HTTP
request ID when one is available. None of that is derived from the person's network or browser.

It records **nothing** about the request itself — no IP address, no browser user-agent, no
IP-geolocation field — until the initializer or a policy says otherwise. Saying otherwise takes
one line:

```ruby
Clickwrap.configure do |config|
  config.record_request_evidence_by_default = true
end
```

That switch records exactly what its name says and nothing else: the IP address, the browser
user agent, and a coarse country / region / city estimate. Every finer geolocation field — a
postal code, coordinates, a timezone, a continent, a metro code, an accuracy radius — remains
its own separately named line, and no option here turns a category on as a side effect of
turning on something else. There is still no profile switch and no name that hides its
contents (`gdpr_compliant_mode`, `maximum_evidence`, `legal_proof`); a switch that reads
`record_request_evidence_by_default` is the opposite of one.

The gem's own default is still record-nothing, and that default is evidence design, not
squeamishness. Three things follow from it:

- An IP address and other online identifiers can be personal data. The CJEU addressed dynamic
  IP addresses in [Breyer, Case C-582/14](https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX%3A62014CJ0582)
  *(case)*. Keeping the value on your own infrastructure does not remove purpose limitation,
  data minimization, storage limitation, transparency, security, or protection-by-default
  duties ([GDPR Article 5](https://eur-lex.europa.eu/eli/reg/2016/679/art_5/oj/eng),
  [Article 13](https://eur-lex.europa.eu/eli/reg/2016/679/art_13/oj/eng),
  [Article 25](https://eur-lex.europa.eu/eli/reg/2016/679/art_25/oj/eng),
  [Article 32](https://eur-lex.europa.eu/eli/reg/2016/679/art_32/oj/eng)) *(law)*.
- Request evidence corroborates; it does not repair. In
  [Berman v. Freedom Financial Network](https://cdn.ca9.uscourts.gov/datastore/opinions/2022/04/05/20-16900.pdf)
  and [Tejon v. Zeus Networks](https://media.ca11.uscourts.gov/opinions/pub/files/202411114.pdf)
  *(cases)* weak notice and ambiguous action defeated the asserted agreement; more IP metadata
  would not have changed either outcome. [Toth v. Everly Well](https://www.ca1.uscourts.gov/sites/ca1/files/opnfiles/23-1727P-01A.pdf)
  *(case)* turned on a clear checkbox, linked terms, placement, and affirmative action.
- Active browser and device fingerprinting is out of scope for the base gem entirely. EDPB
  Guidelines 2/2023 explain that fingerprinting and collection of protocol/device information
  can fall within the technical scope of ePrivacy Directive Article 5(3), with exemptions
  requiring case-specific analysis
  ([official PDF](https://www.edpb.europa.eu/system/files/documents/2024-10/edpb_guidelines_202302_technical_scope_art_53_eprivacydirective_v2_en_0.pdf))
  *(regulator guidance)*. Clickwrap emits no canvas, audio, font, hardware, GPS, or
  high-entropy Client Hint probe anywhere.

The ordering below is a product-design inference drawn from those cases and from the principle
that evidence is assessed with all its circumstances and the accuracy of the producing process
([Federal Rule of Evidence 901](https://www.law.cornell.edu/rules/fre/rule_901)) *(law)*. It is
not a statutory ranking:

1. exact content and conspicuous presentation;
2. explicit action by an authenticated actor;
3. atomic binding to the protected transaction;
4. integrity, reproducibility, and lifecycle; then
5. IP address, browser user-agent, and estimated IP geolocation.

---

## How to read the dictionary

Four tables follow, one per group. Columns are the same in each:

- **Field** — the exact name in the schema, the receipt, and the privacy inventory.
- **What it is** — one sentence.
- **Where it comes from** — the reader, resolver, or computation that produced it.
- **Does not establish** — the overclaim this field invites, said out loud.
- **Encrypted** — whether the value itself is encrypted at rest for this recorded annex.
- **Who can read it** — who gets the value rather than a state word.
- **In a default export** — whether `to_canonical_json` / `Clickwrap.export_receipt` with no
  `include_*` flags contains it.
- **Deletion trigger** — what makes it go away.
- **After deletion the receipt says** — the state a reader sees afterwards.

Two rules apply to every row in every table.

**Reading a raw value is authorized and recorded.** `Clickwrap.export_receipt` will not return
`ip_address`, `browser_user_agent`, or IP-geolocation values unless you name that category
explicitly, supply a non-empty `because:`, and
`config.authorize_unredacted_request_evidence_access_with` returns true for the request. The
default callback returns `false` for everyone. Every authorized read appends a `ReceiptAccess`
row recording who asked, why, and which categories were included.

**Absence is never blank.** Every field reports one of six states —
`not_configured`, `unavailable`, `recorded`, `redacted_for_this_viewer`,
`deleted_after_retention`, `held` — so "we chose not to collect this", "collection failed",
"you may not see this", and "we deleted it on schedule" never look alike.

---

## IP address

The raw address and everything recorded alongside it.

| Field | What it is | Where it comes from | Does not establish | Encrypted | Who can read it | In a default export | Deletion trigger | After deletion the receipt says |
|---|---|---|---|---|---|---|---|---|
| `ip_address` | The single address observed for this HTTP request | `config.read_ip_address_from_http_request_with`, whose default is `->(http_request) { http_request.remote_ip }` | Who was at the keyboard. Addresses are shared, reassigned, NATed, proxied, and routed through VPNs | Yes — `encrypt_recorded_ip_addresses` is `true` by default and applies Active Record encryption to the `ip_address_ciphertext` column | Only a viewer for whom `authorize_unredacted_request_evidence_access_with` returns true, with a `because:` | No | Whichever the policy set: `delete_after:` writes `ip_address_delete_after` at capture, `retain_until:` writes `ip_address_retain_until_rule`. Otherwise `config.delete_recorded_ip_addresses_after`. Applied by `clickwrap:retention:apply` or `Clickwrap.delete_recorded_ip_address!` | `{"state": "deleted_after_retention", "deleted_at": "..."}` |
| `ip_address_reader_name` | Which reader produced the address: `rails_request_remote_ip` or `host_configured_reader` | Compared against a fresh `Configuration`'s default lambda; any host-assigned reader is labeled `host_configured_reader` even if its body is identical | That the address is correct. It says whose logic to blame or credit | No | Same as the address | No | Kept — it explains where the deleted value came from | Unchanged |
| `trusted_proxy_configuration_digest` | A digest of the host's reviewed trusted-proxy configuration, if the host set one | `config.trusted_proxy_configuration_digest` (default `nil`) | That the configuration was correct. It records which configuration was in force | No | Same as the address | No | Kept | Unchanged |
| `ip_address_recorded_at` | When the address was written | Server clock at capture | Anything about the person | No | Same as the address | No | Kept | Unchanged |
| `ip_address_delete_after` | The date this value became due for deletion | Written at capture from the policy or configuration rule | — | No | Same as the address | No | Kept | Unchanged |
| `ip_address_retain_until_rule` | The name of the host retention calculation governing this value, when a duration could not express it | Written at capture from `retain_until:` | That the rule has resolved. It may not have | No | Same as the address | No | Kept | Unchanged |
| `ip_address_deleted_at` | When the value was deleted | Set by the disposition | — | No | Same as the address | No | — | This is what makes the state `deleted_after_retention` |
| `ip_address_unavailable_reason` | Why no address was stored: `no_http_request`, `capture_channel_carries_no_http_request`, `no_ip_address_on_http_request`, or `ip_address_reader_returned_a_forwarded_chain` | Set instead of a value when the reader produced nothing usable | — | No | Anyone who can read the receipt | Yes — it appears in the fragment when the state is `unavailable` | — | — |

`ip_address_reader_returned_a_forwarded_chain` deserves its own sentence. If the configured
reader hands back a value containing a comma, Clickwrap refuses to store it. Everything after
the first trusted hop in a forwarding chain is client-supplied and can be anything at all;
filing a whole chain under "the address the server observed" would present attacker-controlled
input as an observation.

---

## Browser user-agent

| Field | What it is | Where it comes from | Does not establish | Encrypted | Who can read it | In a default export | Deletion trigger | After deletion the receipt says |
|---|---|---|---|---|---|---|---|---|
| `browser_user_agent` | The raw `User-Agent` header string the client sent | `config.read_browser_user_agent_from_http_request_with`, default `->(http_request) { http_request.user_agent }` | Device identity, a unique fingerprint, or what was actually rendered on screen. The header is client-supplied and can say anything | Yes — `encrypt_recorded_browser_user_agents` is `true` by default and applies Active Record encryption to `browser_user_agent_ciphertext` | Only a viewer for whom `authorize_unredacted_request_evidence_access_with` returns true, with a `because:` | No | Policy `delete_after:` / `retain_until:`, else `config.delete_recorded_browser_user_agents_after`. Applied by `clickwrap:retention:apply` or `Clickwrap.delete_recorded_browser_user_agent!` | `{"state": "deleted_after_retention", "deleted_at": "..."}` |
| `browser_user_agent_was_client_supplied` | Always `true` | Set unconditionally when a user-agent is recorded | — it is the qualifier, not a claim | No | Same as the value | No | Kept | Unchanged |
| `browser_user_agent_recorded_at` | When the header was written | Server clock at capture | — | No | Same as the value | No | Kept | Unchanged |
| `browser_user_agent_delete_after` | The date this value became due for deletion | Written at capture | — | No | Same as the value | No | Kept | Unchanged |
| `browser_user_agent_retain_until_rule` | Named host retention calculation, when `retain_until:` was used | Written at capture | — | No | Same as the value | No | Kept | Unchanged |
| `browser_user_agent_deleted_at` | When the value was deleted | Set by the disposition | — | No | Same as the value | No | — | This is what makes the state `deleted_after_retention` |
| `browser_user_agent_unavailable_reason` | Why no header was stored: `no_http_request`, `capture_channel_carries_no_http_request`, or `no_browser_user_agent_on_http_request` | Set instead of a value | — | No | Anyone who can read the receipt | Yes, when the state is `unavailable` | — | — |

Browsers are actively reducing what this header says. Chrome's own documentation covers both
the legitimate uses and the fingerprinting risk, and describes reduced-granularity User-Agent
information alongside explicit higher-entropy Client Hints
([User-Agent Client Hints](https://developer.chrome.com/docs/privacy-security/user-agent-client-hints))
*(vendor documentation)*. Clickwrap records the raw header only. It requests no Client Hints,
and the signed presentation manifest — not this string — remains the evidence of what the
server offered.

---

## IP geolocation: the nine data fields

Each is a separate `record_ip_geolocation(...)` keyword and a separate line in the privacy
inventory, because each one is a separate decision about what to keep about somebody's network
context. `latitude_and_longitude` is one coupled choice on purpose: half a coordinate is not a
result.

Everything in this table shares four properties, so they are stated once rather than repeated
in every cell:

- **Where it comes from:** the configured `ip_geolocation_resolver` — one provider's estimate
  about the observed IP address at resolution time. Nothing here is measured.
- **Encrypted:** yes, when `encrypt_recorded_ip_geolocation` is true, which is the default.
  Every value column below is in `Clickwrap::RequestEvidence::ENCRYPTED_COLUMNS` and carries
  ciphertext at rest — including the country code, which is lower precision than a coordinate
  but is still personal data once it is attached to an identified actor and an event.
  Coordinates are stored as strings rather than decimals for this reason and one other: a
  receipt serializes them as strings anyway, so a decimal column would put a rounding step
  between what the provider said and what the evidence shows.

  The **provenance** columns beside them — provider name, provider source, database version and
  digest, accuracy radius, estimated flag, resolution time, unavailable reason — are
  deliberately *not* encrypted. They say how certain the values are rather than what they are,
  they are what `clickwrap:doctor` and `Clickwrap::Privacy.inventory` read, and encrypting them
  would hide the uncertainty while leaving the estimate itself just as sensitive.
- **Who can read it / in a default export:** only a viewer authorized for the
  `ip_geolocation` category with a `because:`; never in a default export.
- **Deletion trigger and result:** one category, one deletion. Deleting IP geolocation nulls
  every value column below at once and leaves all provenance intact, so the receipt reports
  `{"state": "deleted_after_retention", "deleted_at": "..."}` rather than a gap.

| Field (policy keyword) | Columns it unlocks | What it is | Does not establish |
|---|---|---|---|
| `country` | `ip_geolocation_country_code`, `ip_geolocation_country_name` | The country the provider associates with the address | Nationality, residence, applicable law, or where the person was. It must never select governing law, jurisdiction, terms, or eligibility on its own |
| `region` | `ip_geolocation_region_name`, `ip_geolocation_region_code` | The first-level subdivision the provider associates with the address | Presence in that region |
| `city` | `ip_geolocation_city_name` | The city the provider associates with the address | That anyone was in that city. A city result can describe a wide radius |
| `postal_code` | `ip_geolocation_postal_code` | The postal area the provider associates with the address | A street address or a household |
| `latitude_and_longitude` | `ip_geolocation_latitude`, `ip_geolocation_longitude` | Approximate coordinates for the address | GPS, device location, or a position. Read them with the accuracy radius or not at all |
| `timezone` | `ip_geolocation_timezone` | The timezone the provider reports for the address | The person's timezone or their device's clock setting |
| `continent` | `ip_geolocation_continent_code` | The continent code the provider reports | Anything the country field does not already fail to establish |
| `metro_code` | `ip_geolocation_metro_code` | The provider's metro/DMA code for the address | A place. It is a media-market identifier |
| `accuracy_radius_in_kilometers` | `ip_geolocation_accuracy_radius_in_kilometers` | The radius within which the provider expects the true address location to fall | Precision. A large radius is the provider being honest, not a defect |

MaxMind states expressly that GeoIP data cannot identify a household, an individual, or a
street address, and that accuracy varies by IP type, country, mobile network, VPN/proxy use,
and ISP practice
([geolocation accuracy](https://support.maxmind.com/knowledge-base/articles/maxmind-geolocation-accuracy),
[City database fields](https://dev.maxmind.com/geoip/docs/databases/city-and-country/city-binary/))
*(vendor documentation)*. Cloudflare describes its visitor-location headers as location
information for the visitor's **IP address**
([IP geolocation](https://developers.cloudflare.com/network/ip-geolocation/))
*(vendor documentation)*.

So a receipt may say:

> Estimated country associated with the observed IP address according to provider X at capture
> time.

It may not say:

> User location: Madrid.

A revealed receipt reports these as a single `ip_geolocation` object carrying only the
authorized fields, with `country` rendered from the country **code**, `region` from the region
code when there is one and the name otherwise, and `latitude_and_longitude` as a nested pair
that is omitted entirely unless both halves are present.

---

## IP geolocation: the provenance fields

These are not a policy choice. Any stored IP-geolocation result carries them, and so does any
failure to produce one. A country code with no provider behind it, or coordinates with no
resolution time, invites a reader to treat a guess about an address as a fact about a person.

| Field | What it is | Where it comes from | Does not establish | Encrypted | Who can read it | In a default export | Deletion trigger | After deletion the receipt says |
|---|---|---|---|---|---|---|---|---|
| `ip_geolocation_provider_name` | Which provider actually answered, e.g. `maxmind` or `cloudflare` | The resolver's own `provider_name`; the Trackdown adapter copies the answering provider even under `:auto` | That the provider was right | No | Authorized `ip_geolocation` viewers | No | Kept after deletion | Unchanged |
| `ip_geolocation_provider_source` | Which source answered, e.g. a MaxMind local database or Cloudflare request headers | The resolver's result; the Trackdown adapter copies its per-result `provider_source` | That the source was accurate or arrived over a trusted path | No | Authorized `ip_geolocation` viewers | No | Kept | Unchanged |
| `ip_geolocation_database_version` | The provider database build the answer came from | The resolver, when it exposes one | That the build was current | No | Authorized `ip_geolocation` viewers | No | Kept | Unchanged |
| `ip_geolocation_database_sha256` | A digest of that database build | The resolver, when it exposes one | That the digest was independently checked | No | Authorized `ip_geolocation` viewers | No | Kept | Unchanged |
| `ip_geolocation_accuracy_radius_confidence_percentage` | The confidence the provider attaches to its accuracy radius | The resolver, when it exposes one | Precision. It is the provider's own statistic about its own estimate | No | Authorized `ip_geolocation` viewers | No | Kept | Unchanged |
| `ip_geolocation_was_estimated` | Always `true` for a stored result | Set unconditionally: no IP-geolocation answer from any provider is an observation | — it is the qualifier | No | Authorized `ip_geolocation` viewers | No | Kept | Unchanged |
| `ip_geolocation_source_was_verified_by_host` | Whether the host's verifier vouched for the exact request path | The resolver's per-result trust state. Trackdown defaults request-backed results to unverified and calls the host's provider-specific verifier for each request | That the verifier was designed or deployed correctly. Clickwrap records the result; the host owns that proof | No | Authorized `ip_geolocation` viewers | No | Kept | Unchanged |
| `ip_geolocation_resolved_at` | When the estimate was produced | The resolver's own time, or the server clock at extraction when the resolver reports none | Anything about the person | No | Authorized `ip_geolocation` viewers | No | Kept | Unchanged |
| `ip_geolocation_unavailable_reason` | Why no estimate was stored | See the list below | — | No | Anyone who can read the receipt | Yes, when the state is `unavailable` | — | — |
| `ip_geolocation_recorded_at` | When the estimate was written | Server clock at capture | — | No | Authorized `ip_geolocation` viewers | No | Kept | Unchanged |
| `ip_geolocation_delete_after` / `ip_geolocation_retain_until_rule` | The schedule recorded at capture | Policy `delete_after:` / `retain_until:`, else the configuration default | — | No | Authorized `ip_geolocation` viewers | No | Kept | Unchanged |
| `ip_geolocation_deleted_at` | When the values were deleted | Set by the disposition | — | No | Authorized `ip_geolocation` viewers | No | — | This is what makes the state `deleted_after_retention` |

There are six distinct reasons an estimate can be missing, and they are kept apart because
they tell an auditor completely different things:

| Reason | What actually happened |
|---|---|
| the IP address's own unavailable reason | There was no address to resolve, so there was nothing to ask about |
| `ip_geolocation_resolver_raised_<ErrorClass>` | The resolver raised. The error **class** is recorded and the message never is, because a provider message can quote the address |
| `resolver_returned_no_result` | The resolver returned nothing at all |
| a reason supplied by the resolver | The resolver explained its own failure — the Trackdown adapter emits `no_ip_address_to_resolve`, `provider_returned_no_result`, `provider_supplied_no_location_fields`, or `trackdown_raised_<ErrorClass>` |
| `provider_supplied_no_authorized_field` | The provider answered, and had no value for any field this policy authorized |
| `resolver_cannot_supply_authorized_fields` | The provider can never supply the authorized fields. That is a configuration problem, not a fact about this address |

---

## Enabling a field

Two places, and the policy always wins.

**In the initializer, for every policy.** Either the one switch, or the individual settings —
each field has its own, and each is `false`:

```ruby
Clickwrap.configure do |config|
  config.record_ip_address_by_default = true
  config.reason_for_recording_ip_addresses_by_default =
    "Investigate account compromise and disputes about recorded actions"
  config.legal_basis_reference_for_recording_ip_addresses_by_default = "LIA-SECURITY-2026-01"
  config.delete_recorded_ip_addresses_after = 90.days
end
```

Everything below the first line there is optional. A purpose you do not write becomes
Clickwrap's own stated one (marked `gem_default` in the inventory); a deletion period you do
not set means the field keeps pace with the evidence it corroborates.

Three things are still a `ConfigurationError` at the end of the `configure` block rather than a
warning: scaffolding text standing in for a purpose, a deletion clock set alongside
`keep_recorded_..._indefinitely!` for the same category, and enabling a
`record_ip_geolocation_*_by_default` field with no `ip_geolocation_resolver` configured *and*
no `trackdown` in the bundle — there would be nothing to resolve them with.

**In one policy, for one flow.** This is the shape most applications want: ordinary signup
inherits nothing, and the one consequential action opts in by name.

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

  record_browser_user_agent(
    encrypted: true,
    retain_until: :security_evidence_retention_ends,
    because: "Corroborate the client context used for this action",
    legal_basis_reference: "LIA-SECURITY-2026-01"
  )

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
    retain_until: :security_evidence_retention_ends,
    because: "Corroborate anomalous access and investigate action disputes",
    legal_basis_reference: "LIA-SECURITY-2026-01",
    data_protection_impact_assessment_reference: "DPIA-2026-04"
  )

  retain_with :regulated_evidence
end
```

Every keyword there is doing work, and **every one of them is optional**. The same three
declarations with nothing at all supplied are valid, and record the same fields:

```ruby
Clickwrap.policy :frictionless_regulated_authorization do
  authorize :regulated_action, one_time: true, valid_for: 10.minutes

  record_ip_address
  record_browser_user_agent
  record_ip_geolocation
  retain_with :regulated_evidence
end
```

`record_ip_geolocation` with no field named records the coarse trio — country, region, city —
and nothing finer. Name even one field and the set is exactly what you named; name every field
`false` and Clickwrap refuses, because calling `record_ip_geolocation` and disabling everything
cannot mean anything (`do_not_record_ip_geolocation` is how to say that).

What each keyword adds when you do supply it:

- **`because:`** is the present purpose, in a sentence someone outside engineering can read. It
  is stored and printed by `bin/rails clickwrap:privacy:inventory`. It is optional: a policy
  that omits it records Clickwrap's own stated purpose instead, and the inventory marks that
  entry `"purpose_source": "gem_default"` so nobody mistakes it for a sentence your team
  reviewed. What is refused is scaffolding text — `"TODO: ask legal"` is not a purpose.
- **`legal_basis_reference:`** and **`data_protection_impact_assessment_reference:`** are
  host-supplied pointers to your own reviewed documents. Clickwrap stores them. It does not
  read them, validate them, endorse them, or ever require them — nothing in the gem refuses a
  recorded field for want of either, and nothing ever will. Your privacy policy owns the why;
  the gem records the what.
- **`delete_after:`** and **`retain_until:`** are both optional. When neither the policy, its
  retention class, nor the configuration names a schedule, the field keeps pace with the
  evidence it corroborates — the same posture the core event has — and the annex is stamped
  with no deadline at all, so the retention planner never lists it. Setting a clock alongside
  an application-wide `keep_recorded_..._indefinitely!` for the same category is still refused:
  those are opposite decisions.
- **`fail_if_unavailable:`** (default `false`) decides whether evidence you cannot get is worse
  than no capture at all. When it is `true` and the field cannot be resolved, the capture and
  the protected action roll back together.
- **`review_request_evidence_configuration_on`** is a date by which someone should look at this
  again. `bin/rails clickwrap:doctor` reports policies that collect personal data without one,
  and policies whose date has passed.

Two things you cannot do, by construction: a browser cannot submit or replace any of these
values, and the form helper renders no hidden field carrying an IP address, user-agent,
geolocation field, policy version, validity window, or retention rule. A native or API client
may send a separately labeled `client_reported_*` value only where a host adapter permits it,
and it stays labeled that way forever.

Confirm what a configuration actually does before you trust it:

```bash
bin/rails clickwrap:privacy:inventory
```

---

## Trusted proxies, and why `request.remote_ip` alone is not enough

Clickwrap's default reader is `request.remote_ip`. That is the conventional Rails answer and
the right starting point, but the value it returns is only as good as the proxy topology Rails
was told about.

`ActionDispatch::RemoteIp` inspects potentially forwarded headers, discards addresses matching
the configured trusted proxies, and performs a spoof check — and Rails documents that the
middleware can be wrong when the deployment does not match the proxy behavior it assumes
([`ActionDispatch::RemoteIp`](https://api.rubyonrails.org/classes/ActionDispatch/RemoteIp.html))
*(vendor documentation)*. If your origin is reachable directly, a client can simply send an
`X-Forwarded-For` header of its choosing, and nothing downstream can tell the difference.

So "we record IP addresses" is not one decision. It is four:

1. **Configure the proxies.** Set `config.action_dispatch.trusted_proxies` to the actual
   ranges your load balancer, CDN, or mesh uses. The default trusts private ranges only.
2. **Close the side door.** If requests can reach your application without passing through
   that infrastructure, the header is attacker-controlled no matter what Rails is configured
   with. Block direct origin access, or have trusted infrastructure strip and re-set the
   headers before your application sees them.
3. **Test it.** Send a request with a forged `X-Forwarded-For` through your real path and
   assert on the address Clickwrap stored. The gem's own suite has fixtures for exactly this;
   yours should too, because the failure is silent.
4. **Record which configuration was in force.** Set
   `config.trusted_proxy_configuration_digest` from the effective rules themselves:

   ```ruby
   config.trusted_proxy_configuration_digest =
     Clickwrap.trusted_proxy_configuration_digest_for_rails_application
   ```

   This uses `config.action_dispatch.trusted_proxies`, or Rails' actual default rules when the
   application has not overridden them. A prose description such as "our Cloudflare setup" is
   not configuration provenance. The digest still does not make the setup correct. It lets a
   later reader identify which rules were in force — the difference between corroborating
   evidence and a number with no recorded collection context.

   Since 0.3.0 this step is not a precondition for recording an address. Leave it unset and the
   annex stores `trusted_proxy_configuration_digest` as `nil`, which is the honest reading of
   the situation: nobody recorded having reviewed a proxy topology when this address was
   observed. `bin/rails clickwrap:doctor` warns while it stays that way. Hosts who complete
   step 4 get the stronger record; hosts who do not get an address that says what it is worth.

If you replace the reader, you own that decision, and the receipt says so: any host-assigned
lambda is labeled `host_configured_reader` rather than `rails_request_remote_ip`, even when the
body is identical. Clickwrap will not claim Rails' spoof checks on your behalf.

Finally: Clickwrap does not store an `X-Forwarded-For` chain, and refuses a reader that returns
one. If your topology genuinely needs a different address than `remote_ip` gives you, pick it
in your own reader and pick exactly one.

---

## Trackdown

`trackdown` is the optional official IP-geolocation resolver. It is not a dependency of this
gem and must never become one.

```bash
bundle add trackdown --version ">= 0.4"
```

That is the whole wiring step. When your bundle carries trackdown and you have not named a
resolver of your own, Clickwrap uses `Clickwrap::IpGeolocation::TrackdownResolver` for any
policy that records IP geolocation — lazily, only at the moment something actually needs an
address resolved, and never as a collection decision on its own (nothing is resolved until a
policy has already enabled a geolocation field). `bin/rails clickwrap:privacy:inventory` reports
that resolver with `"source": "gem_default"`, and `clickwrap:doctor` names it, so an adopted
resolver never reads as a host decision. An installed trackdown older than 0.4 is not hidden
behind "the gem is missing": you get the adapter's own sentence about upgrading.

Set it explicitly when you want a different provider per policy, or when you are wiring
Trackdown's per-request CDN trust:

```ruby
# clickwrap-doc-test: syntax-only — requires the optional trackdown gem installed above
Trackdown.configure do |trackdown|
  # This flag must be set by infrastructure that actually authenticated or
  # allowlisted the Cloudflare-to-origin path. It must not come from CF-* header
  # presence, because a client reaching the origin can send those headers too.
  trackdown.verify_request_came_through_trusted_cloudflare_path_with do |request|
    request.env["my_app.cloudflare_origin_was_verified"] == true
  end
end

Clickwrap.configure do |config|
  config.ip_geolocation_resolver = Clickwrap::IpGeolocation::TrackdownResolver.new
end
```

The adapter is where the evidence discipline lives:

- **Only the policy's allowlist is persisted.** Trackdown's `to_h` includes `country_info`, the
  whole ISO3166 country record — reasonable for a general geolocation gem, wrong for evidence.
  The adapter copies named fields one at a time and the extractor then keeps only the subset
  the server-owned policy authorized.
- **Placeholders are mapped back to nothing.** Trackdown returns the string `"Unknown"` for a
  country or city it could not determine, and Cloudflare's own "no country" code is `"XX"`.
  Written into a receipt those would be indistinguishable from a country a provider actually
  reported, so they become `nil` and the result is recorded as unavailable with a reason.
- **The minimum version fails loudly.** Trackdown 0.4 is required because it supplies
  per-result provider, source, resolution time, uncertainty, database provenance, and
  per-request host trust. An older loaded version is refused at the initializer line instead
  of making Clickwrap invent those facts.
- **Every optional field read is defensive.** A field one Trackdown provider cannot supply is
  `nil` instead of an exception in the middle of a capture.
- **`estimated` is always true.** No provider's answer is an observation of where anybody was.
- **Trust is per request, never process-wide.** Clickwrap passes the exact `http_request` from
  the protected capture to `Trackdown.locate`. Trackdown runs the provider-specific host
  verifier on that request and returns `source_was_verified_by_host?`; the adapter copies that
  answer. The former experimental constructor-wide boolean is refused because it could bless
  direct-origin requests after one deployment claim.
- **Cloudflare header presence is not trust.** Trackdown's
  [Cloudflare provider](https://github.com/rameerez/trackdown/blob/v0.4.0/lib/trackdown/providers/cloudflare_provider.rb)
  reads request environment values, while its
  [configuration](https://github.com/rameerez/trackdown/blob/v0.4.0/lib/trackdown/configuration.rb)
  leaves results unverified unless the host's callback vouches for that request. Follow
  Trackdown's exact
  [origin-protection guidance](https://github.com/rameerez/trackdown/blob/v0.4.0/README.md#did-the-request-really-come-through-your-cdn);
  `CF-*` header presence alone is never the callback.

Trackdown 0.4's
[result object](https://github.com/rameerez/trackdown/blob/v0.4.0/lib/trackdown/location_result.rb)
exposes the answering provider and source, resolution time, explicit availability and estimate
state, MaxMind accuracy radius and database build metadata, and per-request source trust. The
work was reviewed in [Trackdown PR #9](https://github.com/rameerez/trackdown/pull/9) and closed
the contract scoped in [Trackdown issue #8](https://github.com/rameerez/trackdown/issues/8).
The adapter copies only named fields. It serializes the exact MaxMind build epoch as
`database_build_epoch:<integer>` and normalizes a 64-hex database digest to Clickwrap's
`sha256:<hex>` form.

**Other providers.** `config.ip_geolocation_resolver` accepts anything responding to
`#resolve(ip_address, http_request: nil)` and `#capabilities`;
`Clickwrap::IpGeolocation::Resolver` is the full contract. The explicit request keyword keeps
request-backed provenance from being discarded by an adapter. A resolver that does not need
the request still accepts and ignores it. For tests, use
`Clickwrap::IpGeolocation::StaticResolver`, which answers from a fixed table — a real provider
makes request-evidence assertions fail because a database was rebuilt rather than because the
allowlist changed.

---

## Footprinted is analytics, not the evidence backend

`footprinted` is a good analytics gem and the wrong place for authoritative assent evidence.
That is a statement about defaults, not about quality. At pinned commit `03b714bd` it:

- requires an IP address and automatically expands it into country, city, region, timezone,
  latitude, and longitude
  ([model](https://github.com/rameerez/footprinted/blob/03b714bd3fa31368a8ce6695433386128fb6f91c/lib/footprinted/footprint.rb#L7-L52));
- permits asynchronous event creation
  ([tracking concern](https://github.com/rameerez/footprinted/blob/03b714bd3fa31368a8ce6695433386128fb6f91c/lib/footprinted/model.rb#L21-L65));
- rescues geolocation failures and proceeds
  ([model](https://github.com/rameerez/footprinted/blob/03b714bd3fa31368a8ce6695433386128fb6f91c/lib/footprinted/footprint.rb#L38-L52));
- accepts arbitrary JSON metadata and stores broad geolocation columns
  ([migration template](https://github.com/rameerez/footprinted/blob/03b714bd3fa31368a8ce6695433386128fb6f91c/lib/generators/footprinted/templates/create_footprinted_footprints.rb.erb#L5-L31)); and
- destroys footprints with the tracked parent
  ([association](https://github.com/rameerez/footprinted/blob/03b714bd3fa31368a8ce6695433386128fb6f91c/lib/footprinted/model.rb#L7-L9)).

All *(pinned source code)*.

Line them up against what evidence needs and the mismatch is structural, not stylistic:

| Footprinted behavior | What evidence requires instead |
|---|---|
| An IP address is required | Every field is off until a policy names it, and an event with no request evidence at all is normal |
| Enabling tracking enables broad geolocation | Nine fields, nine separate decisions, each with its own purpose and retention rule |
| Writes may be asynchronous | Required request evidence resolves before the transaction and commits inside it, or the protected action rolls back |
| Geolocation failure is rescued and the write proceeds | Failure is recorded as an explicit `unavailable` state with a reason, and a policy may choose to fail closed |
| Footprints are destroyed with the tracked parent | Deleting an actor never cascades evidence; disposition is planned, reviewed, hold-aware, and itself recorded |

What is fine, and what the design actually anticipates, is a sanitized analytics copy emitted
after commit — an event ID, a policy key, a kind, perhaps an explicitly approved country code:

```ruby
config.after_event_is_committed = lambda do |event|
  Analytics::ClickwrapEventJob.perform_later(event.id, event.policy_key)
end
```

That copy is never the evidence that authorized the protected action, and an analytics failure
can never undo or stand in for the Clickwrap event. Clickwrap ships no Footprinted adapter.

---

## Sources

| Source | Class |
|---|---|
| [Breyer, Case C-582/14](https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX%3A62014CJ0582) | Case |
| [Berman v. Freedom Financial Network](https://cdn.ca9.uscourts.gov/datastore/opinions/2022/04/05/20-16900.pdf) | Case |
| [Tejon v. Zeus Networks](https://media.ca11.uscourts.gov/opinions/pub/files/202411114.pdf) | Case |
| [Toth v. Everly Well](https://www.ca1.uscourts.gov/sites/ca1/files/opnfiles/23-1727P-01A.pdf) | Case |
| [GDPR Article 5](https://eur-lex.europa.eu/eli/reg/2016/679/art_5/oj/eng), [13](https://eur-lex.europa.eu/eli/reg/2016/679/art_13/oj/eng), [25](https://eur-lex.europa.eu/eli/reg/2016/679/art_25/oj/eng), [32](https://eur-lex.europa.eu/eli/reg/2016/679/art_32/oj/eng) | Law |
| [Federal Rule of Evidence 901](https://www.law.cornell.edu/rules/fre/rule_901) | Law |
| [EDPB Guidelines 2/2023 on the technical scope of ePrivacy Article 5(3)](https://www.edpb.europa.eu/system/files/documents/2024-10/edpb_guidelines_202302_technical_scope_art_53_eprivacydirective_v2_en_0.pdf) | Regulator guidance |
| [MaxMind geolocation accuracy](https://support.maxmind.com/knowledge-base/articles/maxmind-geolocation-accuracy) | Vendor documentation |
| [MaxMind City database fields](https://dev.maxmind.com/geoip/docs/databases/city-and-country/city-binary/) | Vendor documentation |
| [Cloudflare IP geolocation](https://developers.cloudflare.com/network/ip-geolocation/) | Vendor documentation |
| [Chrome User-Agent Client Hints](https://developer.chrome.com/docs/privacy-security/user-agent-client-hints) | Vendor documentation |
| [`ActionDispatch::RemoteIp`](https://api.rubyonrails.org/classes/ActionDispatch/RemoteIp.html) | Vendor documentation |
| [Ironclad bulk retrieval, `connection_data.remote_address`](https://clickwrap-developer.ironcladapp.com/docs/retrieving-data-in-bulk) | Vendor documentation |
| [RFC 791](https://www.rfc-editor.org/info/rfc791/) — IPv4 addresses are 32 bits, which is why the annex binding digest is keyed rather than a plain hash | Technical standard |
| [Trackdown v0.4.0 result object](https://github.com/rameerez/trackdown/blob/v0.4.0/lib/trackdown/location_result.rb), [configuration](https://github.com/rameerez/trackdown/blob/v0.4.0/lib/trackdown/configuration.rb), [Cloudflare provider](https://github.com/rameerez/trackdown/blob/v0.4.0/lib/trackdown/providers/cloudflare_provider.rb), [MaxMind provider](https://github.com/rameerez/trackdown/blob/v0.4.0/lib/trackdown/providers/maxmind_provider.rb), [PR #9](https://github.com/rameerez/trackdown/pull/9) | Pinned released source and project change record |
| [Footprinted pinned model](https://github.com/rameerez/footprinted/blob/03b714bd3fa31368a8ce6695433386128fb6f91c/lib/footprinted/footprint.rb#L7-L52), [tracking concern](https://github.com/rameerez/footprinted/blob/03b714bd3fa31368a8ce6695433386128fb6f91c/lib/footprinted/model.rb#L7-L65) | Pinned source code |
| The field selection, the ordering of evidentiary priority, and every API prescription above | Product-design inference |
