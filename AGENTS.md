# AGENTS.md

This file provides guidance to AI Agents (like OpenAI's Codex, Cursor Agent, Claude Code, etc) when working with code in this repository.

Please read the `README.md` for a full overview of the gem's API and philosophy, and the `guides/` directory for the detailed integration guides. The product research corpus lives in `docs/`, which is deliberately git-ignored; read it if it is present locally, and never publish it.

This gem is part of a coherent ecosystem (`railsfast`, `sessions`, `chats`, `moderate`, `organizations`, `pricing_plans`, `usage_credits`, `wallets`, `api_keys`). Match the ecosystem conventions exactly: a single `Clickwrap.configure do |config| … end` block, `has_*`/verb-style class macros, adapter objects + no-op-default hook procs, string class names constantized lazily, adaptive install migrations, Minitest with a `test/dummy` app, SimpleCov, and the README/docs voice.

## What makes this gem different to work on

Clickwrap's value is evidence that is still true and still verifiable years after it was written. That makes a few ordinary habits actively dangerous here:

1. **Never overclaim in a public string.** No public name, comment, error message, receipt field, task output, generated file, or documentation line may say or imply: compliant, GDPR compliant, enforceable, legally binding, court-proof, tamper-proof, audit approved, trusted time, qualified electronic signature, verified identity, physical location (for IP geolocation), that a person read or understood something, or anything that reads as legal advice. The gem provides evidence mechanics; the host application and its counsel own the legal text, lawful basis, substantive validity, capacity, authority, and retention periods.
2. **Distinguish source classes.** In documentation, keep law, court decisions, regulator guidance, technical standards, vendor claims, pinned source-code observations, and product-design inferences visibly separate. Add an exact, direct URL for every external factual or legal claim, and pin source-code citations to immutable commits rather than moving branches.
3. **Released evidence formats are permanent.** Every released receipt schema, canonicalization profile, digest field, event action, and lifecycle meaning gets a golden fixture, and new versions must keep verifying old receipts. A format change means a new explicit schema and verifier, never a silent reinterpretation. Do not edit a released migration underneath an installed application; add an upgrade migration.
4. **Required writes cannot be error-isolated.** Evidence and the protected database action commit together or not at all. Optional after-commit hooks, analytics, and notifications are isolated and can never undo a committed action or stand in for one.
5. **The browser is not a policy author.** Policy key, revision, document versions, validity, subject binding, retention, and request-evidence fields are resolved server-side and rechecked at submit. Never add a hidden field, parameter, or header that lets a client choose any of them.
6. **Default to collecting nothing.** IP address, browser user-agent, and every individual IP-geolocation field stay off until a policy names them with a plain-English purpose and a retention decision. Never add an option that enables a category of personal data as a side effect of enabling something else, and never add an opaque profile switch (`gdpr_compliant_mode`, `full_evidence`, `maximum_evidence`, `legal_proof`).
7. **Names read aloud.** Complete verb-and-noun names, positive booleans, destructive methods that say exactly what they delete, `ip_address` not `ip`, `browser_user_agent` not `ua`, `ip_geolocation` not `location`, `http_request` not `context`, `recorded_at_by_server` not `signed_at`. If an example does not make sense read aloud by a developer who has never seen the gem, the name is wrong.

## Working here

- Run `bundle exec rake test` before claiming anything works, and `bundle exec rubocop` before committing.
- Add tests in the same change. Fault injection, concurrency, replay, stale-token, disposition, and golden-receipt tests are load-bearing, not extras.
- Prefer explaining a refusal in a full sentence over raising a terse error. The policy compiler's job is to tell a developer what is wrong and what to do about it.
- Do not add a runtime dependency. Every integration is an optional adapter with a working no-op default.
- Do not publish, push, or create anything outside this repository without the owner asking for it.
