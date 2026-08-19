# Security Policy

`clickwrap` stores legal-evidence records: frozen document snapshots, signed presentation tokens, append-oriented evidence events with fixed named disposition transitions, canonical receipts, and — only when a policy explicitly asks for them — encrypted IP addresses, browser user-agent strings, and IP-geolocation estimates. Please report suspected vulnerabilities privately, and do not include real evidence records, receipts, presentation tokens, IP addresses, or any other personal data in a report. Redact or synthesize a reproduction instead; a minimal fabricated policy and document reproduce almost every issue just as well.

## Supported versions

Security fixes are released for the latest published version. The maintained test matrix covers Ruby 3.2, 3.3, 3.4, and 4.0 with patched Rails 7.1, 7.2, 8.0, and 8.1 releases. Older Ruby and Rails versions may remain installable for compatibility, but runtimes that no longer receive upstream security fixes are not security-supported.

## Reporting a vulnerability

Use GitHub's **Report a vulnerability** button on the [`clickwrap` security advisories page](https://github.com/rameerez/clickwrap/security/advisories) so the report and any proposed fix remain private. If GitHub's private reporting flow is unavailable, email `rubygems@rameerez.com` with the subject `clickwrap security report`.

Include:

- the affected version and environment;
- a minimal reproduction or proof of concept, using synthetic documents, policies, and actors;
- the impact you believe is possible — in particular, whether it affects the capture path (evidence that could be recorded wrongly) or only the verifier/display path (evidence that could be read or rendered wrongly); and
- any suggested mitigation or patch.

Do not open a public issue for an undisclosed vulnerability. We will acknowledge the report, investigate it, and coordinate disclosure and credit with you. If the issue affects downstream applications, we will prioritize a patched release and clear upgrade guidance, and say plainly whether historical evidence needs review.

## Operational security

`clickwrap` provides evidence mechanics. Applications remain responsible for:

- Rails credentials, the `secret_key_base` that signs presentation tokens, and the `ActiveRecord::Encryption` keys that protect the request-evidence annex — including key rotation and a documented recovery path, since evidence outlives the deployment that wrote it;
- trusted-proxy configuration (`config.hosts`, `config.action_dispatch.trusted_proxies`) so that `request.remote_ip` reflects the connection the application actually observed rather than a client-supplied header;
- CSRF protection, session cookie configuration, authentication, and the authorization of every controller action that renders a policy or submits evidence;
- database, backup, replica, log, and observability access controls, and keeping presentation tokens and request evidence out of application and proxy logs;
- deciding who may read unredacted request evidence, wiring `config.authorize_receipt_access_with` and `config.authorize_unredacted_request_evidence_access_with` accordingly, and auditing that access; and
- retention periods, legal holds, and disposition decisions — the gem executes the retention classes you write and refuses to dispose of held evidence, but the periods, the lawful basis for keeping or deleting a record, and the decision to place or release a hold are yours.

The gem does not, and does not claim to, provide compliance with any law, enforceability of any agreement, tamper-proof storage, trusted or attested time, or verified identity. A receipt is evidence of what your application recorded and can be verified against its own canonical bytes; it is not proof that the recorded facts are true, that a person read or understood a document, or that the record could not have been fabricated by someone who controls every source. Independent anchors and provider signatures add only the origin and time evidence they actually supply.
