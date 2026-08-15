# frozen_string_literal: true

# The standalone verifier's dependency list is the feature. It requires JSON,
# the canonicalizer, the digest helpers, the error classes, and the version
# constants — and nothing else. No Rails, no ActiveRecord, no database, no
# engine, no host application, no policy source.
#
# That is what makes an exported receipt worth exporting. A verifier that had
# to boot the application which produced the evidence would only ever be able
# to tell you that the application agrees with itself. This one runs in a bare
# `ruby -r` on a machine that has never heard of your product, five years from
# now, from a file and a folder of documents.
#
# `require_relative` rather than `require` on purpose: the four files below sit
# next to this one in the gem, and resolving them by path means the verifier
# works whether or not anyone remembered to put `lib` on the load path.
require "json"

require_relative "errors"
require_relative "version"
require_relative "canonical_json"
require_relative "digest"

module Clickwrap
  # Verifies an exported canonical receipt.
  #
  # ===========================================================================
  # WHAT A SUCCESSFUL VERIFICATION HERE DOES AND DOES NOT ESTABLISH.
  #
  # It DOES establish:
  #
  #   * that the file is well-formed JSON in a receipt schema this verifier
  #     knows by name;
  #   * that its bytes are canonical under RFC 8785, so two readers digest the
  #     same thing;
  #   * that the digest the receipt carries matches the receipt body it
  #     travels with, so accidental or ordinary modification of those bytes is
  #     detected;
  #   * that each document file you supplied hashes to the digest the receipt
  #     recorded for it, so the bundle is internally consistent; and
  #   * that any chain links present are consistent with each other.
  #
  # It does NOT establish:
  #
  #   * that the receipt was not fabricated. A self-contained file verifying
  #     against itself proves internal consistency and nothing about origin. A
  #     party who controlled the application, the database, and the export
  #     could have produced every byte in it, including the digest, and this
  #     verifier would say "verified" — because the only thing it can compare
  #     the bytes against is the bytes;
  #   * WHEN anything happened. `recorded_at_by_server` is a time an
  #     application server wrote down. It is not attested by anyone else;
  #   * WHO acted. An actor reference identifies a record in someone's
  #     database, not a person;
  #   * that any of it is legally sufficient, adequately presented, or
  #     admissible anywhere. That is not a property of a file.
  #
  # Origin and time evidence come from things this verifier cannot supply on
  # its own: an independent anchor holding the chain head somewhere the
  # database operator does not control, an RFC 3161 or trust-service timestamp,
  # or a provider's own signed receipt. Where those exist, they are reported as
  # exactly the assurance they supply, and where they do not, their absence is
  # visible rather than papered over by a green check mark.
  # ===========================================================================
  module ReceiptVerifier
    # Every receipt schema this verifier can read.
    #
    # THIS LIST ONLY EVER GROWS. A released evidence format is permanent: a new
    # gem version may stop *creating* an old schema, but it must never stop
    # *verifying* one, because the receipts already exported under it are out
    # in the world and their whole value is that they still check out years
    # later. A format change means a new entry here and a new branch of
    # verification logic — never a silent reinterpretation of an old name.
    KNOWN_SCHEMAS = ["clickwrap.receipt.v1"].freeze

    # The key that holds the digest, and which is therefore excluded from the
    # bytes the digest covers. See `body_covered_by_digest` for the precise
    # rule and the reason it has to work this way.
    INTEGRITY_KEY = "integrity"

    # `receipt_digest`, not `event_digest`. The two are different values and
    # answer different questions: `event_digest` was computed by the application
    # over the event's own canonical body when the event was written, and
    # nothing in a standalone file can re-derive it; `receipt_digest` covers
    # this receipt body and is exactly what a verifier holding only this file
    # can check. Both are reported in the receipt; only this one is verifiable
    # here, and the result says so rather than implying otherwise.
    DIGEST_KEY = "receipt_digest"

    # One thing that was looked at, and what was found. `passed` is nil for a
    # check that could not be run — a document whose bytes were not supplied is
    # neither a pass nor a failure, and collapsing the three states into two is
    # how "we did not look" becomes "we looked and it was fine".
    Check = Data.define(:name, :passed, :detail) do
      def passed? = passed == true
      def failed? = passed == false
      def skipped? = passed.nil?
      def to_s = "#{status_word} #{name}: #{detail}"

      def status_word
        return "ok" if passed?
        return "FAILED" if failed?

        "skipped"
      end
    end

    # The result object. `success?` is true only when every check that ran
    # passed; a skipped check never makes a result succeed and never makes it
    # fail, it just stays visible in `checks`.
    class Result
      attr_reader :schema, :checks

      def initialize(schema:, checks:)
        @schema = schema
        @checks = checks.freeze
        freeze
      end

      def success? = failures.empty?
      def failures = checks.select(&:failed?)
      def skipped = checks.select(&:skipped?)
      def passed = checks.select(&:passed?)

      def to_h
        {
          "success" => success?,
          "schema" => schema,
          "verifier_version" => Clickwrap::VERIFIER_VERSION,
          "checks" => checks.map do |check|
            { "name" => check.name, "passed" => check.passed, "detail" => check.detail }
          end
        }
      end

      def to_s
        lines = ["#{success? ? "VERIFIED" : "NOT VERIFIED"} (#{schema || "unknown schema"})"]
        lines.concat(checks.map { |check| "  #{check}" })
        lines << "  note: #{PROVES}"
        lines.join("\n")
      end

      def inspect = "#<Clickwrap::ReceiptVerifier::Result #{success? ? "success" : "failure"}>"
    end

    # Printed with every result, so nobody has to go looking for the caveat.
    PROVES =
      "A successful verification shows this receipt is internally consistent and its bytes have " \
      "not changed since the digest was taken. It does not show who produced it, when, or that " \
      "a party controlling every source could not have fabricated the whole file. Independent " \
      "anchors and provider signatures are what add origin and time evidence."

    class << self
      # Verifies `canonical_json_string`.
      #
      # `documents:` maps a document key (or "key@version") to the exact bytes
      # of that document. Any document not supplied is reported `not_supplied`
      # rather than assumed fine.
      def verify(canonical_json_string, documents: {})
        checks = []

        body = parse(canonical_json_string, checks)
        return Result.new(schema: nil, checks: checks) if body.nil?

        schema = body["schema"]
        return Result.new(schema: schema, checks: checks) unless check_schema(schema, checks)

        check_canonical_bytes(canonical_json_string, body, checks)
        check_event_digest(body, checks)
        check_documents(body, documents, checks)
        check_chain_linkage(body, checks)

        Result.new(schema: schema, checks: checks)
      end

      # Same, but raises rather than returning a failed result. Useful in a
      # script where a bad receipt should stop the run.
      #
      # An unknown schema gets its own error class, because it is a different
      # problem with a different fix: the receipt is probably fine and this
      # verifier is too old to read it.
      def verify!(canonical_json_string, documents: {})
        result = verify(canonical_json_string, documents: documents)
        return result if result.success?

        unknown = result.failures.find { |check| check.name == "known_schema" }
        raise UnknownReceiptSchema, unknown.detail if unknown

        raise ReceiptInvalid, result.to_s
      end

      def known_schema?(schema) = KNOWN_SCHEMAS.include?(schema.to_s)

      # The exact bytes a receipt's `integrity.event_digest` covers: the whole
      # receipt body with the `integrity` key removed, canonicalized per RFC
      # 8785.
      #
      # The exclusion is not a convenience. A digest cannot cover itself: the
      # moment the digest is written into the object, the object's bytes change
      # and the digest no longer matches them, and no amount of recomputation
      # converges. So the digest is taken over the body BEFORE `integrity` is
      # attached, and verification reproduces that by removing the key again.
      #
      # The exclusion is precisely the top-level `integrity` key and nothing
      # else. Every other key — including `verifier_instructions` and any host
      # `x_`-prefixed extension — is inside the digest. A key that were excluded
      # without being named here would be a key anyone could edit freely, which
      # is the opposite of the point.
      def body_covered_by_digest(body)
        body.reject { |key, _| key == INTEGRITY_KEY }
      end

      private

      def parse(text, checks)
        if text.nil? || text.to_s.empty?
          checks << Check.new(name: "json_parses", passed: false, detail: "The receipt was empty.")
          return nil
        end

        body = JSON.parse(text.to_s)

        unless body.is_a?(Hash)
          checks << Check.new(name: "json_parses", passed: false,
                              detail: "A receipt is a JSON object; this one is a #{body.class}.")
          return nil
        end

        checks << Check.new(name: "json_parses", passed: true, detail: "Parsed as a JSON object.")
        body
      rescue JSON::ParserError => error
        checks << Check.new(name: "json_parses", passed: false,
                            detail: "The receipt is not valid JSON: #{error.message}")
        nil
      end

      # An unknown schema fails honestly and stops. It is NOT read on a
      # best-effort basis: guessing at the meaning of a format this verifier
      # has never seen would produce a confident answer about a document it
      # does not understand, which is worse than no answer at all.
      def check_schema(schema, checks)
        if known_schema?(schema)
          checks << Check.new(name: "known_schema", passed: true,
                              detail: "Schema #{schema} is one this verifier knows.")
          return true
        end

        checks << Check.new(
          name: "known_schema", passed: false,
          detail: "Schema #{schema.inspect} is not one this verifier knows " \
                  "(#{KNOWN_SCHEMAS.join(", ")}). Verification stopped rather than guessing at " \
                  "the meaning of a newer format. Use a Clickwrap release that lists this schema."
        )
        false
      end

      def check_canonical_bytes(text, body, checks)
        canonical = CanonicalJson.generate(body)

        if canonical == text.to_s
          checks << Check.new(name: "canonical_bytes", passed: true,
                              detail: "The bytes are already canonical under RFC 8785.")
          return
        end

        # Not a failure of the evidence. Pretty-printing a receipt on the way
        # through a bug tracker changes the bytes without changing the meaning,
        # and the digest below is taken over the re-canonicalized form anyway.
        checks << Check.new(
          name: "canonical_bytes", passed: true,
          detail: "The supplied bytes are not in canonical form; they were re-canonicalized per " \
                  "RFC 8785 before digesting. Formatting differs, meaning does not."
        )
      rescue CanonicalJson::SerializationError => error
        checks << Check.new(name: "canonical_bytes", passed: false,
                            detail: "The receipt cannot be canonicalized: #{error.message}")
      end

      def check_event_digest(body, checks)
        integrity = body[INTEGRITY_KEY]

        unless integrity.is_a?(Hash) && integrity[DIGEST_KEY].to_s != ""
          checks << Check.new(
            name: "receipt_digest", passed: nil,
            detail: "This receipt carries no integrity.#{DIGEST_KEY}, so there is nothing to " \
                    "check the body against."
          )
          return
        end

        recorded = integrity[DIGEST_KEY].to_s
        algorithm = Digest.algorithm_of(recorded)

        unless algorithm && Digest.supported?(algorithm)
          checks << Check.new(
            name: "receipt_digest", passed: false,
            detail: "integrity.#{DIGEST_KEY} is #{recorded.inspect}, which does not name a " \
                    "digest algorithm this verifier supports (#{Digest::SUPPORTED_ALGORITHMS.keys.join(", ")})."
          )
          return
        end

        computed = Digest.digest_canonical(body_covered_by_digest(body), algorithm: algorithm)

        checks << if Digest.secure_compare?(computed, recorded)
                    Check.new(
                      name: "receipt_digest", passed: true,
                      detail: "The recorded #{algorithm} digest matches the canonicalized receipt body " \
                              "with the integrity key excluded."
                    )
                  else
                    Check.new(
                      name: "receipt_digest", passed: false,
                      detail: "The recorded digest #{recorded} does not match the body. Computed #{computed} " \
                              "over the canonicalized receipt with the integrity key excluded. Something " \
                              "about these bytes changed after the digest was taken."
                    )
                  end
      end

      # Each document in the receipt is checked against the bytes supplied for
      # it, and reported `not_supplied` when none were. A bundle you did not
      # bring is not a bundle that passed.
      def check_documents(body, documents, checks)
        entries = Array(body["documents"])
        supplied = normalize_documents(documents)

        if entries.empty?
          checks << Check.new(name: "documents", passed: nil,
                              detail: "This receipt cites no document versions.")
          return
        end

        entries.each_with_index do |entry, index|
          check_one_document(entry, index, supplied, checks)
        end
      end

      def check_one_document(entry, index, supplied, checks)
        key = entry["key"].to_s
        version = entry["version"].to_s
        name = "document:#{key.empty? ? index : key}#{version.empty? ? "" : "@#{version}"}"
        expected = entry["digest"].to_s
        bytes = supplied["#{key}@#{version}"] || supplied[key]

        if bytes.nil?
          checks << Check.new(
            name: name, passed: nil,
            detail: "not_supplied — no bytes were provided for this document, so its recorded " \
                    "digest #{expected} was not checked against anything."
          )
          return
        end

        checks << if Digest.matches?(bytes, expected)
                    Check.new(name: name, passed: true,
                              detail: "The supplied bytes hash to the recorded digest #{expected}.")
                  else
                    Check.new(
                      name: name, passed: false,
                      detail: "The supplied bytes do not hash to #{expected}. These are not the bytes this " \
                              "receipt says were presented."
                    )
                  end
      end

      # Chain linkage, when a receipt carries any. A single receipt can only
      # show that its own links are internally coherent — a scope with a
      # sequence, a previous digest that is well-formed. Proving a chain has
      # not been rewritten needs the neighbouring receipts and a head held
      # somewhere the database operator does not control, and this verifier
      # says so rather than implying it checked more than it did.
      def check_chain_linkage(body, checks)
        integrity = body[INTEGRITY_KEY]
        return unless integrity.is_a?(Hash)

        scope = integrity["chain_scope"]
        sequence = integrity["chain_sequence"]
        previous = integrity["previous_event_digest"]

        if scope.nil? && sequence.nil? && previous.nil?
          checks << Check.new(
            name: "chain_linkage", passed: nil,
            detail: "This receipt is not chained. Chaining is optional and off by default; its " \
                    "absence is a configuration fact, not a finding."
          )
          return
        end

        problems = chain_problems(scope, sequence, previous)

        checks << if problems.empty?
                    Check.new(
                      name: "chain_linkage", passed: true,
                      detail: "Chain scope #{scope.inspect} at sequence #{sequence} links to #{previous}. " \
                              "Internally consistent only: verifying that the chain itself was not " \
                              "rewritten needs the neighbouring receipts and an independently held head."
                    )
                  else
                    Check.new(name: "chain_linkage", passed: false, detail: problems.join(" "))
                  end
      end

      def chain_problems(scope, sequence, previous)
        problems = []
        problems << "The receipt has chain fields but no chain_scope." if scope.nil?

        if sequence.nil?
          problems << "The receipt has a chain_scope but no chain_sequence."
        elsif !sequence.is_a?(Integer) || sequence.negative?
          problems << "chain_sequence #{sequence.inspect} is not a non-negative integer."
        end

        if previous && Digest.algorithm_of(previous).nil?
          problems << "previous_event_digest #{previous.inspect} is not an algorithm-prefixed digest."
        end

        # Sequence zero is the head of a chain and legitimately has no
        # predecessor; any later position must name one.
        if previous.nil? && sequence.is_a?(Integer) && sequence.positive?
          problems << "Sequence #{sequence} is not the head of its chain but names no " \
                      "previous_event_digest."
        end

        problems
      end

      def normalize_documents(documents)
        (documents || {}).to_h { |key, value| [key.to_s, value] }
      end
    end
  end
end
