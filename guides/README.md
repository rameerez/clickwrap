# Clickwrap guides

The [README](../README.md) is the tour: it gets you from install to a verified receipt and
shows each capability briefly. These guides are the depth behind the parts that are easy to
get subtly wrong, and they assume you have already read the README section they expand on.

| Guide | Read it when |
|---|---|
| [Integrating](integrating.md) | When you are wiring the gem into a real application — or pointing an AI agent at the job. The battle-tested playbook from a full production migration: install order, real legal content, test setup, Devise bridges, custom surfaces, protecting a money path, importing history, and the dual-write rollout doctrine. |
| [Request evidence](request-evidence.md) | Before you enable IP address, browser user-agent, or any IP-geolocation field. It is the data dictionary: one row per field, where it comes from, what it does not establish, who can read it, and what happens to it when it is deleted. |
| [Receipts and verification](receipts-and-verification.md) | When you need to hand a receipt to somebody outside your application, or explain exactly what a green verification result covers. Also the canonicalization profile, if you are writing a verifier of your own. |
| [Retention and legal holds](retention-and-legal-holds.md) | When your retention periods come from a real obligation rather than a round number, when a duration cannot express the schedule, or before the first time you run a disposition against production data. |
| [Integrity](integrity.md) | When someone asks how strong the audit trail is, or which of the five tiers you are actually on. Includes the threat model as a list of "what happens if" scenarios. |
| [Consent and lifecycle](consent-and-lifecycle.md) | When you are choosing between `agree_to`, `acknowledge`, and `consent_to` for a specific screen, or when you need the full state and action table for a kind. |
| [Migrating](migrating.md) | When you have an `accepted_terms_at` column or a FinePrint installation and you want the history without inventing the parts of it nobody recorded. |
| [Accessibility](accessibility.md) | Before your accessibility review, so you know exactly which line is the reference views' responsibility and which is your page's. |
| [Naming](naming.md) | Before you propose a public method, option, configuration setting, or receipt field — or before you review a pull request that adds one. |
| [Organizations](organizations.md) | When a human user accepts or authorizes something on behalf of an organization. Separates actor, represented party, tenant, subject, membership evidence, and the legal-authority boundary. |

Two things hold across all of them.

**Clickwrap is evidence mechanics.** It records what was offered, what was answered, and what
committed alongside it. Your application and its counsel own the words, the lawful basis, the
retention periods, the identity questions, and every legal conclusion. Nothing in these guides
is advice about any of that.

**Every external claim here carries an exact URL and a source class.** Law, court decisions,
regulator guidance, technical standards, vendor documentation, and this project's own design
inferences are labeled separately, because they carry very different weight. Source-code
citations are pinned to commit `a1ffe9b` of this repository rather than to a moving branch.
