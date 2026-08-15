# frozen_string_literal: true

module Clickwrap
  module Integrity
    # Walks the optional event chains and reports what still links up.
    #
    #   result = Clickwrap::Integrity::Chain.verify
    #   result.success?     # => true
    #   result.counts       # => {"checked" => 41_882, "verified" => 41_882, "breaks" => 0}
    #   result.first_break  # => nil
    #
    # ============================================================================
    # WHAT A CHAIN DETECTS, EXACTLY. Each event carries the digest of the one
    # before it, so an event that is later rewritten or removed stops linking up
    # with its successors, and this walk finds the first place that happens. That
    # is a real and useful property: ordinary corruption, a well-meant
    # `update_column`, a restored partial backup, and a row edited by hand all
    # show up here.
    #
    # What it does NOT do is stop, or detect, a privileged actor who rewrites an
    # event AND every digest that follows it. Whoever can write the events table
    # can usually write this table too, and a chain whose head lives in the same
    # database as the chain cannot say otherwise. That is precisely the gap the
    # optional independent anchor adapter addresses, and even then the claim is
    # only ever as strong as the anchor. The chain makes rewriting history
    # detectable for as long as the head remains trustworthy — no more than that,
    # and this class never says more than that.
    # ============================================================================
    class Chain
      BATCH_SIZE = 1_000

      # Every way a walk can stop lining up, as a stable symbol so a monitor can
      # branch on it without matching English.
      REASONS = %i[
        digest_does_not_match
        previous_digest_does_not_link
        sequence_gap
        earlier_events_missing
        chain_head_missing
        chain_tail_missing
        chain_head_event_mismatch
        chain_head_digest_mismatch
      ].freeze

      Break = Data.define(:chain_scope, :chain_sequence, :event_id, :reason, :detail) do
        def to_h
          {
            "chain_scope" => chain_scope,
            "chain_sequence" => chain_sequence,
            "event_id" => event_id,
            "reason" => reason.to_s,
            "detail" => detail
          }.compact
        end

        def to_s = "#{chain_scope}##{chain_sequence} #{event_id}: #{detail}"
      end

      Result = Data.define(
        :chaining_enabled,
        :checked,
        :verified,
        :documented_dispositions,
        :scopes,
        :breaks,
        :started_mid_chain
      ) do
        def success? = breaks.empty?
        def first_break = breaks.first

        def counts
          {
            "checked" => checked,
            "verified" => verified,
            "documented_dispositions" => documented_dispositions,
            "breaks" => breaks.length,
            "scopes" => scopes.length
          }
        end

        def to_h
          {
            "chaining_enabled" => chaining_enabled,
            "counts" => counts,
            "scopes" => scopes,
            "started_mid_chain" => started_mid_chain,
            "first_break" => first_break&.to_h,
            "breaks" => breaks.map(&:to_h),
            "detects" => "An event rewritten or removed after it was written, for as long as the " \
                         "chain head remains trustworthy. Not a rewrite of the events and their " \
                         "digests together by a privileged actor."
          }
        end
      end

      # `from:` and `to:` accept either a chain sequence number or a time. A
      # sequence is the natural way to re-check one span of a chain; a time is
      # the natural way to run "everything since last night" from cron, and
      # refusing one of them would just make an operator convert by hand.
      def self.verify(scope: nil, from: nil, to: nil) = new(scope: scope, from: from, to: to).verify

      def initialize(scope: nil, from: nil, to: nil)
        @scope = scope&.to_s
        @from = from
        @to = to
        @breaks = []
        @checked = 0
        @verified = 0
        @documented_dispositions = 0
        @started_mid_chain = []
      end

      attr_reader :scope, :from, :to

      def verify
        scopes = chain_scopes
        scopes.each { |chain_scope| walk(chain_scope) }

        Result.new(
          chaining_enabled: !Clickwrap.config.chain_event_history_with.nil?,
          checked: @checked,
          verified: @verified,
          documented_dispositions: @documented_dispositions,
          scopes: scopes,
          breaks: @breaks,
          started_mid_chain: @started_mid_chain
        )
      end

      private

      def chain_scopes
        return [scope] if scope

        event_scopes = Event.where.not(chain_scope: nil).distinct.pluck(:chain_scope)
        head_scopes = ChainHead.distinct.pluck(:chain_scope)
        (event_scopes + head_scopes).compact.uniq.sort
      end

      def walk(chain_scope)
        previous = nil

        each_event(chain_scope) do |event|
          @checked += 1

          if previous.nil?
            check_first(chain_scope, event)
          else
            check_link(chain_scope, event, previous)
          end

          check_digest(chain_scope, event)
          previous = event
        end

        check_durable_head(chain_scope, previous) if full_chain_walk?
      end

      def check_durable_head(chain_scope, last_event)
        head = ChainHead.find_by(chain_scope: chain_scope)

        unless head
          add_head_break(
            chain_scope,
            last_event,
            :chain_head_missing,
            "Events name this chain scope, but its durable chain-head row is missing. The walk " \
            "cannot establish whether the newest recorded events are still present."
          )
          return
        end

        if last_event.nil?
          return if head.chain_sequence.to_i.zero? && head.last_event_id.blank? && head.last_event_digest.blank?

          add_head_break(
            chain_scope,
            nil,
            :chain_tail_missing,
            "The durable head records sequence #{head.chain_sequence} and event #{head.last_event_id}, " \
            "but this scope has no event rows. Its recorded tail is missing."
          )
          return
        end

        if last_event.chain_sequence != head.chain_sequence
          add_head_break(
            chain_scope,
            last_event,
            :chain_tail_missing,
            "The newest event row is sequence #{last_event.chain_sequence}, while the durable " \
            "head records sequence #{head.chain_sequence}. One or more newest events are missing."
          )
        end

        if last_event.id.to_s != head.last_event_id.to_s
          add_head_break(
            chain_scope,
            last_event,
            :chain_head_event_mismatch,
            "The newest event row is #{last_event.id}, while the durable head names " \
            "#{head.last_event_id}. The head and chain tail do not describe the same event."
          )
        end

        return if Digest.secure_compare?(last_event.event_digest.to_s, head.last_event_digest.to_s)

        add_head_break(
          chain_scope,
          last_event,
          :chain_head_digest_mismatch,
          "The newest event digest does not match the digest retained by the durable chain head."
        )
      end

      # Keyset pagination on the (chain_scope, chain_sequence) index. `find_each`
      # would order by primary key, and the primary key here is a ULID: close to
      # chain order, but "close to" is not the property a chain walk can rely on.
      def each_event(chain_scope, &block)
        cursor = nil

        loop do
          relation = bounded(Event.where(chain_scope: chain_scope)).order(:chain_sequence).limit(BATCH_SIZE)
          relation = relation.where(chain_sequence: (cursor + 1)..) if cursor
          batch = relation.to_a
          break if batch.empty?

          batch.each(&block)
          cursor = batch.last.chain_sequence
          break if cursor.nil?
        end
      end

      def bounded(relation)
        relation = apply_bound(relation, from, :from)
        apply_bound(relation, to, :to)
      end

      def apply_bound(relation, value, side)
        return relation if value.nil?

        column = value.is_a?(Integer) ? :chain_sequence : :recorded_at_by_server
        range = side == :from ? (value..) : (..value)

        relation.where(column => range)
      end

      # The first event of a walk is the one link that cannot be checked against
      # a predecessor this walk has seen. Sequence 1 with no previous digest is a
      # genuine chain start; anything else is either a deliberately bounded run
      # (which is reported, not hidden) or a chain missing its beginning.
      def check_first(chain_scope, event)
        return if event.chain_sequence == 1 && event.previous_event_digest.blank?

        if bounded_run?
          @started_mid_chain << { "chain_scope" => chain_scope, "chain_sequence" => event.chain_sequence }
          return
        end

        add_break(chain_scope, event, :earlier_events_missing,
                  "The walk starts at sequence #{event.chain_sequence}, so the events before it are " \
                  "no longer in the table and nothing can check the link into this one.")
      end

      def check_link(chain_scope, event, previous)
        unless event.chain_sequence == previous.chain_sequence + 1
          add_break(chain_scope, event, :sequence_gap,
                    "Sequence jumps from #{previous.chain_sequence} to #{event.chain_sequence}, so " \
                    "at least one event between them is gone.")
        end

        return if Digest.secure_compare?(event.previous_event_digest.to_s, previous.event_digest.to_s)

        add_break(chain_scope, event, :previous_digest_does_not_link,
                  "This event records a different predecessor digest than event #{previous.id} " \
                  "actually has, so the two no longer form a chain.")
      end

      def check_digest(chain_scope, event)
        case event.digest_integrity_status
        when :verified
          @verified += 1
        when :documented_core_disposition
          @documented_dispositions += 1
        else
          add_break(chain_scope, event, :digest_does_not_match,
                    "Recomputing the canonical body of this event produces a different digest than " \
                    "the one stored with it, and no valid disposition event accounts for the missing " \
                    "payload. Its meaningful bytes changed after it was written or its disposition " \
                    "marker is unexplained. That does not, on its own, say who changed it or when.")
        end
      end

      def add_break(chain_scope, event, reason, detail)
        @breaks << Break.new(chain_scope: chain_scope, chain_sequence: event.chain_sequence,
                             event_id: event.id, reason: reason, detail: detail)
      end

      def add_head_break(chain_scope, event, reason, detail)
        @breaks << Break.new(
          chain_scope: chain_scope,
          chain_sequence: event&.chain_sequence,
          event_id: event&.id,
          reason: reason,
          detail: detail
        )
      end

      def bounded_run? = !from.nil?
      def full_chain_walk? = from.nil? && to.nil?
    end
  end
end
