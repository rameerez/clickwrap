# frozen_string_literal: true

module Clickwrap
  module Integrity
    # The adapter contract for a timestamp provider, plus a reference base
    # implementation that issues no tokens and says so. Configuration defaults
    # to nil.
    #
    #   config.timestamp_receipts_with = MyRfc3161TimestampProvider.new
    #
    # WHAT THIS SEAM IS FOR. Clickwrap records `recorded_at_by_server`, and calls
    # it exactly that: the application server's own clock, which the application
    # controls. An RFC 3161 time-stamp authority
    # (https://www.rfc-editor.org/info/rfc3161/) or a qualified trust service
    # supplies something different — a token from a third party over a digest
    # you gave it, whose value depends entirely on that party, its practice
    # statement, its certificate status, and what a reader is willing to accept
    # about it.
    #
    # WHAT SUCH A TOKEN CLAIMS. Exactly what that provider supplies and nothing
    # more. Clickwrap stores the token and the validation status the adapter
    # reports, and preserves both verbatim; it never upgrades a provider receipt
    # into a guarantee the provider did not make, never treats a token as
    # identity, never treats it as a signature by a person, and never restates
    # it in stronger words than the provider used. If the provider's own status
    # is "unknown" or "expired", that is what travels into the receipt. eIDAS
    # gives distinct legal effect to qualified signatures and seals
    # (https://eur-lex.europa.eu/eli/reg/2014/910/2024-05-20/eng); whether a
    # given provider's output has that effect is a question about that provider,
    # not about this gem.
    #
    # WHAT THIS FILE DELIBERATELY IS NOT. It is not an RFC 3161 client. Clickwrap
    # ships no ASN.1 encoder, no HTTP client, and no certificate-chain
    # validation, and it adds no dependency that would. Timestamping is an
    # optional integration. A host that needs it supplies an adapter that speaks
    # to its own chosen authority; assigning this base class is useful only when
    # an explicit unavailable result is wanted.
    #
    # WRITING ONE. Implement `#timestamp(digest)` and `#verify(token, digest)`,
    # and report honestly from `#capabilities`.
    # `Configuration#timestamp_receipts_with=` checks that the object responds to
    # `#timestamp`.
    class Timestamp
      # What an adapter returns from `#timestamp`. `issued: false` is an
      # ordinary outcome — no provider configured, provider unavailable, request
      # declined — and the record says which rather than leaving a gap where a
      # token should be.
      Token = Data.define(:issued, :token, :digest, :provider_name, :protocol, :issued_at, :detail) do
        def initialize(issued: false, token: nil, digest: nil, provider_name: nil, protocol: nil,
                       issued_at: nil, detail: nil)
          super
        end

        def to_h
          {
            "issued" => issued,
            "token" => token,
            "digest" => digest,
            "provider_name" => provider_name,
            "protocol" => protocol,
            # The provider's own time, described as the provider's own time.
            "provider_reported_time" => issued_at && Receipt.format_time(issued_at),
            "detail" => detail
          }.compact
        end
      end

      # The result of checking a token. `status` carries the provider's own
      # validation vocabulary unchanged, because "valid according to this
      # authority today" is a narrower and more useful statement than "valid".
      Verification = Data.define(:checked, :verified, :status, :provider_name, :protocol, :detail) do
        def initialize(checked: false, verified: false, status: nil, provider_name: nil,
                       protocol: nil, detail: nil)
          super
        end

        def to_h
          {
            "checked" => checked,
            "verified" => verified,
            "provider_reported_status" => status,
            "provider_name" => provider_name,
            "protocol" => protocol,
            "detail" => detail
          }.compact
        end
      end

      # Asks the provider to timestamp one digest. Never the raw receipt, never
      # the personal data inside it: a digest is what a timestamp authority needs
      # and the only thing it should ever be given.
      #
      # Called outside the capture transaction. A provider cannot join a
      # database transaction, and a capture must never fail because a third
      # party was slow.
      def timestamp(digest)
        Token.new(
          issued: false,
          digest: digest,
          provider_name: provider_name,
          detail: "This timestamp adapter issues no token, so the only " \
                  "recorded time remains the application server's own."
        )
      end

      # Checks a stored token against the digest it was issued over, and reports
      # what the provider said. A token nobody re-checks is a stored blob.
      def verify(_token, _digest)
        Verification.new(
          checked: false,
          verified: false,
          provider_name: provider_name,
          detail: "This timestamp adapter issues no token, so there is nothing to check in this " \
                  "token."
        )
      end

      # What this adapter supplies, in the provider's own terms. Read by the
      # receipt's integrity fragment and by `clickwrap:doctor`, which report the
      # tier honestly rather than inferring a stronger one from the mere
      # presence of an adapter.
      def capabilities
        {
          "name" => provider_name,
          "available" => available?,
          "protocol" => nil,
          "supplies" => "Nothing. This is the default placeholder that reports the absence of a " \
                        "timestamp provider for explicit adapter-contract tests. Configuration " \
                        "normally remains nil.",
          "note" => "A configured provider supplies exactly the assurance and validation status " \
                    "that provider supplies. Clickwrap preserves it and never restates it more " \
                    "strongly."
        }
      end

      def available? = false

      def provider_name = "no_timestamp_provider"

      def to_s = "#{self.class.name} (#{provider_name})"
    end
  end
end
