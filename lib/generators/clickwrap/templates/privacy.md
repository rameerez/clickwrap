# PLACEHOLDER — this is not your Privacy Notice

**Replace this entire file before you present it to anyone.**

The `clickwrap` gem generated this placeholder so that `config/clickwrap.rb` has
a file to point at and `bin/rails clickwrap:publish` has bytes to digest. It is
not a privacy notice, and it describes no actual processing.

Clickwrap deliberately never writes legal text. Only you know what your
application collects, why, on what basis, who it goes to, and for how long — and
a notice the gem invented would describe an application that does not exist.

Your notice has to describe what your application actually does, which now
includes whatever `clickwrap` records on your behalf. By default that is the
evidence event itself: an identifier, your server's time, the capture channel,
the policy and application version, the configured actor reference and
authentication context, and the HTTP request id when one is available.

If you enabled anything in the request-evidence section of
`config/initializers/clickwrap.rb` — the IP address, the browser User-Agent, or
any provider-estimated IP-geolocation field — those are personal data too, and
your notice is where you tell people about them. `bin/rails
clickwrap:privacy:inventory` lists exactly what your configuration records,
for which stated purpose, under which retention rule. It reports your
configuration; it does not judge it.

## What to do now

1. Replace this file with your own reviewed Privacy Notice.
2. Set the matching `version:` label in `config/clickwrap.rb`.
3. Run `bin/rails clickwrap:publish` to freeze an immutable snapshot.
4. Publish a NEW version whenever the text changes, so a receipt keeps binding
   the notice version in the accepted server offer.

Note how this document is used in `config/clickwrap.rb`: it is `acknowledge`,
not `agree_to` and not `consent_to`. A notice is information people are entitled
to receive, not a contract term they assent to or permission they grant.
Anything you genuinely need consent for gets its own separate, unselected,
withdrawable consent statement.

If this text ever reaches a real person, something went wrong: check that this
file was replaced, and that `clickwrap:publish` ran against the replacement.
