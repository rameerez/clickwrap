# frozen_string_literal: true

module Clickwrap
  VERSION = "0.3.2"

  # The canonical schema version for receipts, event digests, and presentation
  # manifests. This is deliberately independent of VERSION: gem releases may
  # come and go without changing how historical evidence is serialized, and a
  # change here always means a new explicit schema plus a verifier that still
  # reads every previously released version.
  CANONICAL_SCHEMA_VERSION = "clickwrap.receipt.v1"

  # Bumped only when the receiver-side verification logic changes in a way an
  # auditor should be able to see in a receipt.
  VERIFIER_VERSION = "1"
end
