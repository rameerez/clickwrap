# frozen_string_literal: true

module Clickwrap
  module Services
    # `Clickwrap.authorize_external_action!` — the outbox.
    #
    # ===========================================================================
    # READ THIS BEFORE CHANGING ANYTHING HERE.
    #
    # This is a DISTRIBUTED RELIABILITY PROTOCOL. It is NOT a cross-system ACID
    # transaction, and no amount of care in this file could make it one.
    #
    # Stripe, an identity service, a timestamp authority, a remote signature
    # provider: none of them can enlist in your database transaction. There is
    # no two-phase commit here, no compensating rollback that reaches into
    # someone else's ledger, and no moment at which "the evidence committed" and
    # "the provider acted" are known to be true together. Clickwrap never claims
    # atomicity across two independent systems, and the receipt this produces
    # does not claim it either.
    #
    # What this protocol actually gives you is narrower and achievable:
    #
    #   1. ONE local transaction commits the evidence event and a `pending`
    #      outbox row carrying a server-generated idempotency key.
    #   2. The provider is called OUTSIDE that transaction, by the host, with
    #      that key — so a retry reaches the provider as the same request rather
    #      than as a second one.
    #   3. The outcome is appended back idempotently through
    #      `record_provider_success_and_consume!`, `record_provider_failure!`,
    #      or `record_provider_outcome_unknown!`.
    #   4. `unknown` stays `unknown` until someone or something resolves it.
    #
    # Step 4 is the part people delete first and regret longest. A timeout is
    # not a failure — it is an absence of information. Writing "failed" because
    # the socket closed is how a second debit happens; writing "succeeded"
    # because the retry returned 200 is how a fictional one does. The
    # reconciliation task exists precisely so the ambiguous case can be settled
    # later with better information than we have at the moment it occurs.
    # ===========================================================================
    class AuthorizeExternalAction
      # The key handed to the provider. It is derived from the committed event
      # id, which means one evidence event maps to exactly one external action
      # forever: a retried capture that replays onto the same event reuses this
      # key rather than minting a second one, and a provider that honors
      # idempotency keys will therefore not act twice.
      #
      # It is server-generated. A client-supplied idempotency key would let a
      # browser decide whether a second debit is a duplicate — which is exactly
      # the decision the server exists to make.
      def self.idempotency_key_for(policy_key:, event_id:)
        "clickwrap-#{policy_key}-#{event_id}"
      end

      def initialize(policy:, provider_name: nil, **capture_options)
        @policy = policy
        @provider_name = provider_name&.to_s
        @capture_options = capture_options
      end

      attr_reader :policy, :provider_name, :capture_options

      # Captures the evidence and commits the pending outbox row in ONE local
      # transaction, then returns the ExternalAction so the caller can hand its
      # id and idempotency key to a job.
      #
      # The provider call belongs after this method returns, never inside it. A
      # transaction held open across someone else's network is a transaction
      # holding locks on evidence rows while waiting for a stranger's DNS.
      def call
        action = nil

        receipt = Capture.new(policy: policy, **capture_options).capture_and! do |pending|
          action = create_pending_action!(pending)
        end

        # A replayed capture returns the original receipt without re-running the
        # block, so the outbox row for that event already exists. Finding it is
        # the correct answer: the same authorization, with the same key, not a
        # second one that could produce a second provider call.
        action ||= ExternalAction.find_by(event_id: receipt.event_id)

        unless action
          raise ExternalActionError,
                "The evidence for #{policy.key} committed as event #{receipt.event_id}, but no " \
                "pending external action was found for it. Do not call the provider: without a " \
                "committed outbox row there is nothing to resolve the outcome against."
        end

        action.reload
      end

      private

      def create_pending_action!(pending)
        now = Clickwrap.now

        ExternalAction.create!(
          event_id: pending.event_id,
          policy_key: policy.key,
          idempotency_key: self.class.idempotency_key_for(
            policy_key: policy.key, event_id: pending.event_id
          ),
          provider_name: provider_name,
          state: "pending",
          attempts: 0,
          requested_at: now,
          created_at: now,
          updated_at: now
        )
      end
    end
  end
end
