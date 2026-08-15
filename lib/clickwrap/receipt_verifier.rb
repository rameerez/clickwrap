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
  # its own: an independent publication holding the exact event-chain snapshot somewhere the
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
    # answer different questions: `event_digest` was computed over the embedded
    # event's canonical body when the event was written; `receipt_digest` covers
    # the entire exported projection. The standalone verifier checks both (or a
    # documented disposition in place of a removed event payload), and excludes
    # only this self-referential receipt field when checking the latter.
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

      def verified? = failures.empty? && skipped.empty?
      alias success? verified?

      def failed? = failures.any?
      def incomplete? = failures.empty? && skipped.any?

      def status
        if failed?
          "failed"
        else
          (incomplete? ? "incomplete" : "verified")
        end
      end

      def failures = checks.select(&:failed?)
      def skipped = checks.select(&:skipped?)
      def passed = checks.select(&:passed?)

      def to_h
        {
          "success" => success?,
          "status" => status,
          "schema" => schema,
          "verifier_version" => Clickwrap::VERIFIER_VERSION,
          "checks" => checks.map do |check|
            { "name" => check.name, "passed" => check.passed, "detail" => check.detail }
          end
        }
      end

      def to_s
        lines = ["#{status.upcase} (#{schema || "unknown schema"})"]
        lines.concat(checks.map { |check| "  #{check}" })
        lines << "  note: #{PROVES}"
        lines.join("\n")
      end

      def inspect = "#<Clickwrap::ReceiptVerifier::Result #{status}>"
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
        schema = nil

        body = parse(canonical_json_string, checks)
        return Result.new(schema: nil, checks: checks) if body.nil?

        schema = body["schema"]
        return Result.new(schema: schema, checks: checks) unless check_schema(schema, checks)

        check_canonical_bytes(canonical_json_string, body, checks)
        check_receipt_digest(body, checks)
        check_event_digest(body, checks)
        check_lifecycle_successors(body, checks)
        check_integrity_attestations(body, checks)
        check_documents(body, documents, checks)
        check_chain_linkage(body, checks)

        Result.new(schema: schema, checks: checks)
      rescue StandardError => error
        checks << Check.new(
          name: "verifier_input",
          passed: false,
          detail: "The receipt could not be verified safely because #{error.class}: #{error.message}"
        )
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

      # The exact bytes a receipt's `integrity.receipt_digest` covers: the whole
      # receipt with only that self-referential field removed. Every other
      # integrity claim—including event digest, chain position, tier, and claim
      # sentence—is covered and cannot be edited for free.
      #
      # The exclusion is not a convenience. A digest cannot cover itself: the
      # moment the digest is written into the object, the object's bytes change
      # and the digest no longer matches them, and no amount of recomputation
      # converges. So the digest is taken over the body before this one field is
      # attached, and verification reproduces that by removing the field again.
      #
      # The exclusion is precisely `integrity.receipt_digest` and nothing else.
      # Every other key — including the rest of `integrity`,
      # `verifier_instructions`, and any host
      # `x_`-prefixed extension — is inside the digest. A key that were excluded
      # without being named here would be a key anyone could edit freely, which
      # is the opposite of the point.
      def body_covered_by_digest(body)
        covered = deep_copy(body)
        integrity = covered[INTEGRITY_KEY]
        integrity.delete(DIGEST_KEY) if integrity.is_a?(Hash)
        covered
      end

      private

      def parse(text, checks)
        if text.nil? || text.to_s.empty?
          checks << Check.new(name: "json_parses", passed: false, detail: "The receipt was empty.")
          return nil
        end

        body = JSON.parse(text.to_s, object_class: UniqueKeyHash)

        unless body.is_a?(Hash)
          checks << Check.new(name: "json_parses", passed: false,
                              detail: "A receipt is a JSON object; this one is a #{body.class}.")
          return nil
        end

        checks << Check.new(name: "json_parses", passed: true, detail: "Parsed as a JSON object.")
        body
      rescue JSON::ParserError, DuplicateJsonKey => error
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

        checks << Check.new(
          name: "canonical_bytes", passed: false,
          detail: "The supplied bytes are not in canonical form; they were re-canonicalized per " \
                  "RFC 8785 for the remaining checks, but this file is not the exact canonical " \
                  "receipt artifact Clickwrap exports."
        )
      rescue CanonicalJson::SerializationError => error
        checks << Check.new(name: "canonical_bytes", passed: false,
                            detail: "The receipt cannot be canonicalized: #{error.message}")
      end

      def check_receipt_digest(body, checks)
        integrity = body[INTEGRITY_KEY]

        unless integrity.is_a?(Hash) && integrity[DIGEST_KEY].to_s != ""
          checks << Check.new(
            name: "receipt_digest", passed: false,
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
                              "with only integrity.#{DIGEST_KEY} excluded."
                    )
                  else
                    Check.new(
                      name: "receipt_digest", passed: false,
                      detail: "The recorded digest #{recorded} does not match the body. Computed #{computed} " \
                              "over the canonicalized receipt with only integrity.#{DIGEST_KEY} excluded. Something " \
                              "about these bytes changed after the digest was taken."
                    )
                  end
      end

      def check_event_digest(body, checks)
        integrity = body[INTEGRITY_KEY]
        event_body = body["event"]
        recorded = integrity.is_a?(Hash) ? integrity["event_digest"].to_s : ""

        unless event_body.is_a?(Hash) && !recorded.empty?
          checks << Check.new(
            name: "event_digest", passed: false,
            detail: "The receipt must carry both event and integrity.event_digest so the " \
                    "application's recorded event can be re-derived independently."
          )
          return
        end

        algorithm = Digest.algorithm_of(recorded)
        unless algorithm && Digest.supported?(algorithm)
          checks << Check.new(name: "event_digest", passed: false,
                              detail: "integrity.event_digest does not use a supported algorithm.")
          return
        end

        if body.dig("retention", "core_event_disposed_at").to_s != ""
          check_documented_core_disposition(body, event_body, recorded, checks)
          return
        end

        computed = Digest.digest_canonical(event_body, algorithm: algorithm)
        mismatches = event_projection_mismatches(body, event_body)
        projection_matches = mismatches.empty?

        checks << if Digest.secure_compare?(computed, recorded) && projection_matches
                    Check.new(name: "event_digest", passed: true,
                              detail: "The embedded canonical event and receipt projection match " \
                                      "the recorded #{algorithm} event digest.")
                  else
                    Check.new(
                      name: "event_digest",
                      passed: false,
                      detail: "The embedded event digest or its receipt projection does not match " \
                              "the recorded event evidence. Mismatched projections: " \
                              "#{mismatches.join(", ").empty? ? "(embedded digest)" : mismatches.join(", ")}"
                    )
                  end
      end

      # A retention run deliberately removes the original event payload, so a
      # later export cannot rederive its original digest without defeating the
      # deletion. That is neither a successful digest check nor evidence of
      # tampering. It is an explicit incomplete check, but only after the
      # retained tombstone and the independently digest-checked disposition
      # successor agree on exactly what was disposed, when, and which original
      # digest remains as the historical anchor.
      def check_documented_core_disposition(body, event_body, recorded_digest, checks)
        disposed_at = body.dig("retention", "core_event_disposed_at").to_s
        event_id = body["event_id"].to_s
        problems = event_projection_mismatches(body, event_body)
                   .map { |field| "retained receipt projection differs at #{field}" }

        problems.concat(disposed_tombstone_problems(body, event_body))

        successors = Array(body.dig("lifecycle", "successors"))
        dispositions = successors.select do |successor|
          successor.is_a?(Hash) &&
            successor.dig("event", "protected_outcome", "core_event_disposition").is_a?(Hash)
        end

        if dispositions.one?
          successor_event = dispositions.first["event"]
          facts = successor_event.dig("protected_outcome", "core_event_disposition")
          problems << "disposition names a different event" unless facts["event_id"].to_s == event_id
          problems << "disposition names a different original event digest" unless
            facts["original_event_digest"].to_s == recorded_digest
          problems << "disposition records a different disposal time" unless facts["disposed_at"].to_s == disposed_at
          unless successor_event["event_type"] == "disposition"
            problems << "disposition successor has the wrong event type"
          end

          linked = successor_event["root_event_id"].to_s == event_id ||
                   successor_event["predecessor_event_id"].to_s == event_id
          problems << "disposition successor is not linked to the disposed event" unless linked
        else
          problems << if dispositions.empty?
                        "no core-event disposition successor is present"
                      else
                        "more than one core-event disposition successor is present"
                      end
        end

        checks << if problems.empty?
                    Check.new(
                      name: "event_digest",
                      passed: nil,
                      detail: "The original core event payload was lawfully disposed at #{disposed_at}. " \
                              "The retained tombstone and documented disposition identify its original " \
                              "digest #{recorded_digest}, but that digest cannot be re-derived after the " \
                              "covered payload was deleted."
                    )
                  else
                    Check.new(
                      name: "event_digest",
                      passed: false,
                      detail: "The receipt claims a core-event disposition, but its retained evidence is " \
                              "inconsistent: #{problems.join("; ")}."
                    )
                  end
      end

      def disposed_tombstone_problems(body, event_body)
        problems = []
        problems << "receipt acts remain after disposition" unless body["acts"] == []
        problems << "receipt documents remain after disposition" unless body["documents"] == []
        problems << "embedded event acts remain after disposition" unless event_body["acts"] == []
        problems << "embedded event documents remain after disposition" unless event_body["documents"] == []
        problems << "receipt actor reference remains after disposition" unless body.dig("actor",
                                                                                        "reference").to_s.empty?
        problems << "embedded actor reference remains after disposition" unless
          event_body.dig("actor", "reference").to_s.empty?
        problems << "receipt presentation remains after disposition" unless body["presentation"].nil?
        problems << "embedded presentation remains after disposition" unless event_body["presentation"].nil?
        problems << "receipt protected outcome remains after disposition" unless body["outcome"].nil?
        problems << "embedded protected outcome remains after disposition" unless event_body["protected_outcome"].nil?
        problems
      end

      def check_lifecycle_successors(body, checks)
        successors = body.dig("lifecycle", "successors")
        return if successors.nil?

        unless successors.is_a?(Array)
          checks << Check.new(name: "lifecycle_successors", passed: false,
                              detail: "lifecycle.successors must be an array.")
          return
        end

        seen = {}
        successors.each_with_index do |successor, index|
          check_lifecycle_successor(body, successor, index, seen, checks)
        end
      end

      def check_lifecycle_successor(root_body, successor, index, seen, checks)
        name = "lifecycle_successor:#{index}"
        unless successor.is_a?(Hash) && successor["event"].is_a?(Hash)
          checks << Check.new(name: name, passed: false,
                              detail: "The successor must embed its canonical event body.")
          return
        end

        event = successor["event"]
        event_id = event["event_id"].to_s
        name = "lifecycle_successor:#{event_id.empty? ? index : event_id}"
        recorded = successor["event_digest"].to_s
        algorithm = Digest.algorithm_of(recorded)
        problems = []
        problems << "event id is missing" if event_id.empty?
        problems << "event id is duplicated" if seen[event_id]
        seen[event_id] = true unless event_id.empty?
        problems << "event digest is missing or unsupported" unless algorithm && Digest.supported?(algorithm)

        if algorithm && Digest.supported?(algorithm)
          computed = Digest.digest_canonical(event, algorithm: algorithm)
          problems << "event digest does not match" unless Digest.secure_compare?(computed, recorded)
        end

        projections = {
          "event_id" => [successor["event_id"], event["event_id"]],
          "event_type" => [successor["event_type"], event["event_type"]],
          "recorded_at_by_server" => [successor["recorded_at_by_server"],
                                      event["recorded_at_by_server"]],
          "reason" => [successor["reason"], event["reason"]]
        }
        mismatches = projections.filter_map { |field, values| field unless values[0] == values[1] }
        problems << "summary differs from embedded event (#{mismatches.join(", ")})" if mismatches.any?

        root_id = root_body["event_id"].to_s
        linked = event["root_event_id"].to_s == root_id || event["predecessor_event_id"].to_s == root_id
        problems << "event is not linked to receipt #{root_id}" unless linked

        checks << Check.new(
          name: name,
          passed: problems.empty?,
          detail: if problems.empty?
                    "The embedded successor event and its summary match #{recorded}."
                  else
                    problems.join("; ")
                  end
        )
      end

      def check_integrity_attestations(body, checks)
        attestations = body.dig("integrity", "attestations")
        expected_tier = "baseline"

        if attestations
          unless attestations.is_a?(Array)
            checks << Check.new(name: "integrity_attestations", passed: false,
                                detail: "integrity.attestations must be an array.")
            return
          end

          verified_kinds = attestations.filter_map.with_index do |attestation, index|
            check = check_integrity_attestation(body, attestation, index)
            checks << check
            attestation["kind"] if check.passed? && attestation["state"] == "verified"
          end

          timestamp = attestations.find do |attestation|
            verified_kinds.include?("third_party_timestamp") &&
              attestation.is_a?(Hash) && attestation["kind"] == "third_party_timestamp" &&
              attestation.dig("adapter_capabilities", "independently_verifiable") == true
          end
          external_anchor = attestations.find do |attestation|
            verified_kinds.include?("event_anchor") &&
              attestation.is_a?(Hash) && attestation["kind"] == "event_anchor" &&
              attestation.dig("adapter_capabilities", "publishes_outside_primary_database") == true
          end

          expected_tier = if timestamp
                            "third_party_timestamp"
                          elsif external_anchor
                            "external_event_anchoring"
                          elsif body.dig("integrity", "chain_scope")
                            "chained_history"
                          else
                            "baseline"
                          end
        elsif body.dig("integrity", "chain_scope")
          expected_tier = "chained_history"
        end

        actual_tier = body.dig("integrity", "tier").to_s
        checks << Check.new(
          name: "integrity_tier",
          passed: actual_tier == expected_tier,
          detail: if actual_tier == expected_tier
                    "The advertised #{actual_tier} tier matches the verified evidence in this receipt."
                  else
                    "The receipt advertises #{actual_tier.inspect}, but its verifiable evidence supports " \
                      "#{expected_tier.inspect}."
                  end
        )
      end

      def check_integrity_attestation(body, attestation, index)
        name = "integrity_attestation:#{index}"
        unless attestation.is_a?(Hash)
          return Check.new(name: name, passed: false,
                           detail: "The attestation is not a JSON object.")
        end

        kind = attestation["kind"].to_s
        state = attestation["state"].to_s
        name = "integrity_attestation:#{kind.empty? ? index : kind}:#{index}"
        recorded = attestation["attestation_digest"].to_s
        algorithm = Digest.algorithm_of(recorded)
        body_without_digest = attestation.except("attestation_digest")
        problems = []
        problems << "attestation kind is not recognized" unless
          %w[event_anchor third_party_timestamp].include?(kind)
        problems << "attestation state is not recognized" unless
          %w[verified issued_unverified unavailable failed].include?(state)

        problems << "attestation digest is missing or unsupported" unless algorithm && Digest.supported?(algorithm)
        if algorithm && Digest.supported?(algorithm)
          computed = Digest.digest_canonical(body_without_digest, algorithm: algorithm)
          problems << "attestation digest does not match" unless Digest.secure_compare?(computed, recorded)
        end

        problems << "attestation belongs to a different event" unless
          attestation["event_id"].to_s == body["event_id"].to_s
        problems << "attestation covers a different event digest" unless
          attestation["subject_digest"].to_s == body.dig("integrity", "event_digest").to_s

        if kind == "event_anchor"
          problems << "anchor chain scope differs from this event" unless
            attestation["chain_scope"].to_s == body.dig("integrity", "chain_scope").to_s
          problems << "anchor chain sequence differs from this event" unless
            attestation["chain_sequence"] == body.dig("integrity", "chain_sequence")
        end

        if state == "verified"
          verification = attestation["verification"]
          unless verification.is_a?(Hash) && verification["checked"] == true &&
                 verification["verified"] == true
            problems << "state is verified but the recorded adapter verification is not"
          end
        end

        Check.new(
          name: name,
          passed: problems.empty?,
          detail: if problems.empty?
                    "The attestation record is digest-bound to this exact event. Its provider claim is " \
                      "reported as recorded; cryptographic provider-token verification remains adapter-specific."
                  else
                    problems.join("; ")
                  end
        )
      end

      # Every duplicated immutable fact must agree with the embedded canonical
      # event. Checking only ids, acts, and documents would let someone edit the
      # projected actor, authority, subject, outcome, provider, presentation,
      # retention, chain, or timestamps and recompute the self-contained receipt
      # digest while the protected event digest continued to pass.
      def event_projection_mismatches(body, event)
        comparisons = {
          "event_id" => [body["event_id"], event["event_id"]],
          "event_type" => [body["event_type"], event["event_type"]],
          "policy.key" => [body.dig("policy", "key"), event.dig("policy", "key")],
          "policy.revision" => [body.dig("policy", "revision"), event.dig("policy", "revision")],
          "policy.retention_class" => [body.dig("policy", "retention_class"), event.dig("retention", "class")],
          "actor.reference" => [body.dig("actor", "reference"), event.dig("actor", "reference")],
          "actor.attribution" => [body.dig("actor", "attribution"), event.dig("actor", "attribution")],
          "actor.snapshot" => [body.dig("actor", "snapshot"), event.dig("actor", "snapshot")],
          "actor.authentication_method" => [body.dig("actor", "authentication_method"),
                                            event["authentication_method"]],
          "actor.tenant" => [body.dig("actor", "tenant"), event["tenant"]],
          "actor.subject" => [body.dig("actor", "subject"), event["subject"]],
          "actor.acting_for" => [body.dig("actor", "acting_for"), represented_party_projection(event)],
          "acts" => [body["acts"], event["acts"]],
          "documents" => [body["documents"], event["documents"]],
          "presentation" => [fixed_presentation_projection(body["presentation"]),
                             presentation_projection(event)],
          "outcome" => [body["outcome"], event["protected_outcome"]],
          "provider" => [fixed_provider_projection(body["provider"]), provider_projection(event)],
          "lifecycle.root_event_id" => [body.dig("lifecycle", "root_event_id"), event["root_event_id"]],
          "lifecycle.predecessor_event_id" => [body.dig("lifecycle", "predecessor_event_id"),
                                               event["predecessor_event_id"]],
          "retention.core_event_retained_until" => [body.dig("retention", "core_event_retained_until"),
                                                    event.dig("retention", "retain_core_event_until")],
          "retention.retention_rule" => [body.dig("retention", "retention_rule"),
                                         event.dig("retention", "rule")],
          "integrity.chain" => [receipt_chain_projection(body), event["chain"]],
          "integrity.request_evidence" => [receipt_request_evidence_projection(body),
                                           event["request_evidence"]],
          "recorded_at_by_server" => [body["recorded_at_by_server"], event["recorded_at_by_server"]],
          "occurred_at" => [body["occurred_at"], event["occurred_at"]],
          "system.gem_version" => [body.dig("system", "gem_version"), event["gem_version"]],
          "system.application_version" => [body.dig("system", "application_version"),
                                           event["application_version"]],
          "system.template_version" => [body.dig("system", "template_version"), event["template_version"]],
          "system.canonical_schema_version" => [body.dig("system", "canonical_schema_version"), event["schema"]]
        }

        comparisons.filter_map { |name, pair| name unless pair[0] == pair[1] }
      end

      def represented_party_projection(event)
        represented = event.dig("actor", "represented_party")
        return nil unless represented

        authority = event.dig("actor", "authority") || {}
        compact_hash(
          "type" => represented["type"],
          "reference" => represented["reference"],
          "authority_source" => authority["source"],
          "authority_role" => authority["role"],
          "authority_verified_at" => authority["verified_at"],
          "authority_details" => authority["details"]
        )
      end

      def fixed_presentation_projection(presentation)
        presentation&.except("proves")
      end

      def presentation_projection(event)
        presentation = event["presentation"]
        return nil unless presentation

        manifest = presentation["manifest"] || {}
        compact_hash(
          "manifest_digest" => presentation["manifest_digest"],
          "submit_button_text" => manifest["submit_button_text"],
          "locale" => manifest["locale"],
          "capture_channel" => event["capture_channel"],
          "offered_at" => manifest["issued_at"]
        )
      end

      def fixed_provider_projection(provider)
        provider&.except("note")
      end

      def provider_projection(event)
        provider = event["provider"]
        return nil unless provider

        compact_hash(
          "name" => provider["name"],
          "event_id" => provider["event_id"],
          "verification" => provider["verification"]
        )
      end

      def receipt_chain_projection(body)
        value = compact_hash(
          "scope" => body.dig("integrity", "chain_scope"),
          "sequence" => body.dig("integrity", "chain_sequence"),
          "previous_event_digest" => body.dig("integrity", "previous_event_digest")
        )
        value.empty? ? nil : value
      end

      def receipt_request_evidence_projection(body)
        digests = body.dig("integrity", "request_evidence_category_binding_digests")
        return nil if digests.nil? || digests.empty?

        compact_hash(
          "category_digests" => digests,
          "algorithm" => body.dig("integrity", "request_evidence_digest_algorithm"),
          "key_id" => body.dig("integrity", "request_evidence_key_id")
        )
      end

      def compact_hash(hash)
        hash.compact
      end

      # Each document in the receipt is checked against the bytes supplied for
      # it, and reported `not_supplied` when none were. A bundle you did not
      # bring is not a bundle that passed.
      def check_documents(body, documents, checks)
        entries = Array(body["documents"])
        supplied = normalize_documents(documents)

        if entries.empty?
          checks << Check.new(name: "documents", passed: true,
                              detail: "This receipt cites no document versions to verify.")
          return
        end

        checked = {}
        entries.each_with_index do |entry, index|
          check_one_document(entry, index, supplied, checks, checked)
        end
      end

      def check_one_document(entry, index, supplied, checks, checked)
        unless entry.is_a?(Hash)
          checks << Check.new(name: "document:#{index}", passed: false,
                              detail: "The document binding is not a JSON object.")
          return
        end

        key = entry["key"].to_s
        version = entry["version"].to_s
        locale = entry["locale"].to_s
        identity = document_identity(key, version, locale, fallback: index)
        supplied_entry = supplied[document_identity(key, version, locale)] ||
                         supplied["#{key}@#{version}"] || supplied[key]
        source_bytes = document_artifact_bytes(supplied, supplied_entry, key, version, locale, "source")
        if source_bytes.nil? && !supplied_entry.is_a?(Hash) &&
           entry["source_digest"].to_s == entry["rendered_digest"].to_s
          source_bytes = supplied_entry
        end

        check_document_artifact(
          identity: identity,
          artifact: "source",
          expected: entry["source_digest"],
          bytes: source_bytes,
          checks: checks,
          checked: checked
        )

        check_document_artifact(
          identity: identity,
          artifact: "rendered",
          expected: entry["rendered_digest"],
          bytes: document_artifact_bytes(supplied, supplied_entry, key, version, locale, "rendered"),
          checks: checks,
          checked: checked
        )
      end

      def check_document_artifact(identity:, artifact:, expected:, bytes:, checks:, checked:)
        name = "document:#{identity}:#{artifact}"
        return if checked[name]

        checked[name] = true
        expected = expected.to_s

        if expected.empty? || Digest.algorithm_of(expected).nil?
          checks << Check.new(
            name: name, passed: false,
            detail: "The receipt carries no supported #{artifact}_digest for this document artifact."
          )
          return
        end

        if bytes.nil?
          checks << Check.new(
            name: name, passed: nil,
            detail: "not_supplied — no #{artifact} bytes were provided, so the recorded " \
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
                      detail: "The supplied #{artifact} bytes do not hash to #{expected}. These are not " \
                              "the #{artifact} bytes this receipt binds."
                    )
                  end
      end

      # A caller may be maximally explicit:
      #
      #   { "terms@2026-08" => { source: source_bytes, rendered: html_bytes } }
      #
      # Flat `terms@2026-08:source` / `:rendered` keys work too. A bare String
      # means the rendered representation the receipt records as offered. If
      # source and rendered digests are the same, that one byte string can
      # legitimately verify both artifacts.
      def document_artifact_bytes(supplied, entry, key, version, locale, artifact)
        explicit = supplied["#{document_identity(key, version, locale)}:#{artifact}"] ||
                   supplied["#{key}@#{version}:#{artifact}"] || supplied["#{key}:#{artifact}"]
        return explicit unless explicit.nil?

        if entry.is_a?(Hash)
          return entry[artifact] || entry[artifact.to_sym] || entry["#{artifact}_bytes"] ||
                 entry[:"#{artifact}_bytes"]
        end

        return entry if artifact == "rendered"

        nil
      end

      def document_identity(key, version, locale, fallback: nil)
        parts = [key, version, locale].reject(&:empty?)
        parts.empty? ? fallback.to_s : parts.join("@")
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
            name: "chain_linkage", passed: true,
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

        # Sequence one is the first event of a chain and legitimately has no
        # predecessor; any later position must name one.
        if previous.nil? && sequence.is_a?(Integer) && sequence > 1
          problems << "Sequence #{sequence} is not the first event of its chain but names no " \
                      "previous_event_digest."
        end

        problems
      end

      def normalize_documents(documents)
        (documents || {}).to_h { |key, value| [key.to_s, value] }
      end

      def deep_copy(value)
        case value
        when Hash then value.to_h { |key, nested| [key, deep_copy(nested)] }
        when Array then value.map { |nested| deep_copy(nested) }
        else value
        end
      end
    end

    class DuplicateJsonKey < StandardError; end

    # JSON.parse target that refuses duplicate object keys instead of silently
    # keeping the last value and verifying a different object than a reader saw.
    class UniqueKeyHash < Hash
      def []=(key, value)
        raise DuplicateJsonKey, "The JSON object repeats key #{key.inspect}." if key?(key)

        super
      end
    end
    private_constant :DuplicateJsonKey, :UniqueKeyHash
  end
end
