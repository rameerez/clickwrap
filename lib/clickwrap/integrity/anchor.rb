# frozen_string_literal: true

module Clickwrap
  module Integrity
    # The adapter contract for publishing exact event-chain snapshots somewhere
    # outside the primary database, plus a reference base implementation that
    # publishes nowhere and says so. Configuration itself defaults to nil.
    #
    #   config.anchor_event_history_with = MyIndependentAnchor.new
    #
    # WHY THIS SEAM EXISTS. A chain makes a rewrite of history detectable for as
    # long as a checkpoint remains trustworthy, and the ordinary checkpoint lives
    # in the same database as the events. Whoever can rewrite one can usually
    # rewrite the other. Publishing an exact snapshot somewhere the application cannot quietly edit —
    # an append-only object store with a retention lock, a separate account, a
    # notary, a transparency log, a printout in a safe — narrows that gap.
    #
    # WHAT AN ANCHOR CLAIMS. Exactly what the place it published to can support,
    # and not one word more. Clickwrap records the reference and the receipt an
    # adapter returns; it never upgrades either into a guarantee the anchoring
    # service did not make. An anchor does not make evidence impossible to
    # alter, does not establish identity, and does not supply time — a storage
    # service writing "received at 14:02" is telling you when it received bytes,
    # which is a different claim from a timestamp authority's, and different
    # again from proof that something happened at 14:02.
    #
    # WRITING ONE. Implement `#publish(chain_snapshot)` and
    # `#verify(publication, chain_snapshot)`,
    # and report honestly from `#capabilities`. Subclassing this class is the
    # easy path: `Configuration#anchor_event_history_with=` checks that the
    # object responds to `#anchor`, and the base class provides that name as the
    # entry point to your `#publish`. An adapter written from scratch must
    # respond to `#anchor` as well.
    #
    # Everything here is optional. Configuration defaults to nil; assigning an
    # instance of this base class is an explicit unavailable/no-publication
    # adapter for testing or capability reporting.
    class Anchor
      # What an adapter returns from `#publish`. `anchored: false` is a normal
      # outcome, not an error — a no-op adapter, a provider outage, or a queue
      # that has not drained yet all mean "not anchored", and the honest record
      # says so rather than leaving a caller to infer it.
      Publication = Data.define(:anchored, :reference, :published_at, :provider_name, :detail) do
        def initialize(anchored: false, reference: nil, published_at: nil, provider_name: nil, detail: nil)
          super
        end

        def to_h
          {
            "anchored" => anchored,
            "reference" => reference,
            "published_at" => published_at && Receipt.format_time(published_at),
            "provider_name" => provider_name,
            "detail" => detail
          }.compact
        end
      end

      # `verified: false` with a `detail` is likewise ordinary. "We could not
      # check" and "we checked and it does not match" are different answers, and
      # `checked` keeps them apart.
      Verification = Data.define(:checked, :verified, :reference, :provider_name, :detail) do
        def initialize(checked: false, verified: false, reference: nil, provider_name: nil, detail: nil)
          super
        end

        def to_h
          {
            "checked" => checked,
            "verified" => verified,
            "reference" => reference,
            "provider_name" => provider_name,
            "detail" => detail
          }.compact
        end
      end

      # Publishes this exact chain snapshot outside the primary database. Called after the
      # events it covers have committed, never inside their transaction: an
      # anchoring service cannot join a database transaction, and pretending
      # otherwise is how a network timeout becomes a rolled-back capture.
      def publish(_chain_head)
        Publication.new(
          anchored: false,
          provider_name: provider_name,
          detail: "This anchor adapter publishes nowhere, so this chain snapshot was not published outside " \
                  "the primary database."
        )
      end

      # The name `Configuration#anchor_event_history_with=` checks for. Kept as
      # a thin alias so the contract can read as `publish`/`verify` while the
      # configuration keeps the verb it already documents.
      def anchor(chain_head) = publish(chain_head)

      # Re-reads what was published and compares it with the exact snapshot passed
      # for this event. This is the half that does the work: publishing bytes nobody ever
      # checks establishes nothing.
      def verify(_publication, _chain_head)
        Verification.new(
          checked: false,
          verified: false,
          provider_name: provider_name,
          detail: "This anchor adapter publishes nowhere, so there is no outside publication to compare " \
                  "with this chain snapshot."
        )
      end

      # What this adapter actually supplies, in the words of the thing that
      # supplies it. `clickwrap:doctor` and the receipt's integrity fragment read
      # this rather than assuming a configured adapter means a stronger claim.
      def capabilities
        {
          "name" => provider_name,
          "available" => available?,
          "publishes_outside_primary_database" => false,
          "independently_verifiable" => false,
          "supplies" => "Nothing. This is the default placeholder that reports the absence of an " \
                        "anchor for explicit adapter-contract tests. Configuration normally remains nil."
        }
      end

      def available? = false

      def provider_name = "no_anchor"

      def to_s = "#{self.class.name} (#{provider_name})"
    end
  end
end
