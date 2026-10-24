# frozen_string_literal: true

module Clickwrap
  # `user.clickwraps` — the everyday API.
  #
  # Each predicate reads as the question it answers, and each one asks about the
  # specific act it names. `agreed_to?(:terms)` is not the same question as
  # `consented_to?(:marketing)`, and neither is answered by a generic
  # `accepted_at` timestamp. That is the whole point of having six kinds.
  #
  # Two things these predicates deliberately never do. They never treat a system
  # exemption as a human action — an exemption answers `exempted_from?` and
  # nothing else. And they never infer a "yes" from missing data: no evidence
  # means no, every time.
  class ActorProxy
    def initialize(actor)
      @actor = actor
    end

    attr_reader :actor

    # --- Predicates -----------------------------------------------------------

    def current_for?(policy_key, subject: nil, tenant: nil, acting_for: nil)
      Clickwrap.current?(policy_key, actor: actor, subject: subject, tenant: tenant,
                                     acting_for: acting_for)
    end

    def required_for?(policy_key, subject: nil, tenant: nil, acting_for: nil)
      !current_for?(policy_key, subject: subject, tenant: tenant, acting_for: acting_for)
    end

    def agreed_to?(statement_key, subject: nil, tenant: nil, acting_for: nil)
      satisfied?("agreement", statement_key, subject: subject, tenant: tenant, acting_for: acting_for)
    end

    # Whether the actor agreed to the version in force now of each document
    # this statement binds, under ANY policy that records the statement.
    #
    # Neither neighbour answers this. `agreed_to?` reads the newest agreement
    # and ignores versions. `current_for?` checks versions inside one policy
    # only. A signup form and a re-acceptance screen usually record the same
    # `agree_to :terms` under two policies, so a person who signed up an hour
    # ago has the version in force under `:signup` and nothing under
    # `:current_terms`. A gate on `current_for?(:current_terms)` alone sends
    # that person back to accept the same text again.
    #
    # "In force" is the rule `require_current_version: true` applies: a version
    # with a later `effective_at` counts only from that time, and until then
    # the acceptance of the version it replaces still counts. An agreement that
    # no longer stands does not count. No agreement at all is false.
    def agreed_to_current_version_of?(statement_key)
      states(subject: nil, tenant: nil, acting_for: nil)
        .for_statement(statement_key)
        .where(kind: "agreement")
        .order(effective_at: :desc)
        .any? { |state| state.satisfies? && agreed_to_current_versions?(state) }
    end

    def acknowledged?(statement_key, subject: nil, tenant: nil, acting_for: nil)
      satisfied?("acknowledgment", statement_key, subject: subject, tenant: tenant, acting_for: acting_for)
    end

    def consented_to?(purpose_key, subject: nil, tenant: nil, acting_for: nil)
      state = state_for_purpose(purpose_key, subject: subject, tenant: tenant, acting_for: acting_for)
      !state.nil? && state.satisfies?
    end

    def declared?(statement_key, subject: nil, tenant: nil, acting_for: nil)
      satisfied?("declaration", statement_key, subject: subject, tenant: tenant, acting_for: acting_for)
    end

    def attested?(statement_key, subject: nil, tenant: nil, acting_for: nil)
      satisfied?("attestation", statement_key, subject: subject, tenant: tenant, acting_for: acting_for)
    end

    def authorized?(statement_key, subject: nil, tenant: nil, acting_for: nil)
      satisfied?("authorization", statement_key, subject: subject, tenant: tenant, acting_for: acting_for)
    end

    # Deliberately a separate question. An exemption records that no human
    # action occurred, so it can never answer `agreed_to?` — the whole reason to
    # record one is that the difference matters.
    def exempted_from?(policy_key, subject: nil, tenant: nil, acting_for: nil)
      states(subject: subject, tenant: tenant, acting_for: acting_for)
        .for_policy(policy_key)
        .where(state: "exempted")
        .exists?
    end

    # --- Records --------------------------------------------------------------

    def declaration(statement_key, subject: nil, tenant: nil, acting_for: nil)
      state_for("declaration", statement_key, subject: subject, tenant: tenant, acting_for: acting_for)
    end

    def consent(purpose_key, subject: nil, tenant: nil, acting_for: nil)
      state_for_purpose(purpose_key, subject: subject, tenant: tenant, acting_for: acting_for)
    end

    def authorization(statement_key, subject: nil, tenant: nil, acting_for: nil)
      state_for("authorization", statement_key, subject: subject, tenant: tenant, acting_for: acting_for)
    end

    def events
      Event.for_actor(actor_reference).chronological
    end

    def receipts
      ReceiptCollection.new(events.where(event_type: Vocabulary::ACTOR_RECEIPT_EVENT_TYPES))
    end

    def statement_states = StatementState.for_actor(actor_reference)

    def to_s = "clickwraps for #{actor_reference}"

    private

    def actor_reference
      @actor_reference ||= Reference.actor(actor)
    end

    def states(subject:, tenant:, acting_for:)
      StatementState.for_actor(actor_reference).where(
        subject_key: StatementState.subject_key_for(subject),
        tenant_key: Reference.tenant(tenant),
        represented_party_reference: Reference.represented_party(acting_for)
      )
    end

    # The documents come from the statement as its policy declares it now,
    # exactly as `require_current_version` reads them. Evidence under a policy
    # that is no longer declared has nothing to check against, and "cannot
    # check" is never "yes".
    def agreed_to_current_versions?(state)
      statement = Clickwrap.policies[state.policy_key]&.statement(state.statement_key)
      return false unless statement

      state.document_key_with_unseen_current_version(statement.document_keys).nil?
    end

    def satisfied?(kind, statement_key, subject:, tenant:, acting_for:)
      state = state_for(kind, statement_key, subject: subject, tenant: tenant, acting_for: acting_for)
      !state.nil? && state.satisfies?
    end

    def state_for(kind, statement_key, subject:, tenant:, acting_for:)
      states(subject: subject, tenant: tenant, acting_for: acting_for)
        .for_statement(statement_key)
        .where(kind: kind)
        .order(effective_at: :desc)
        .first
    end

    def state_for_purpose(purpose_key, subject:, tenant:, acting_for:)
      states(subject: subject, tenant: tenant, acting_for: acting_for)
        .where(kind: "consent")
        .for_purpose(purpose_key)
        .order(effective_at: :desc)
        .first
    end

    # A lazily-mapped collection so `user.clickwraps.receipts.last` reads
    # naturally without loading every event a person ever produced.
    class ReceiptCollection
      include Enumerable

      def initialize(scope)
        @scope = scope
      end

      def each(&) = @scope.each { |event| yield Receipt.new(event) }
      def last = @scope.last&.then { |event| Receipt.new(event) }
      def first = @scope.first&.then { |event| Receipt.new(event) }
      def size = @scope.count
      alias count size
      def empty? = @scope.empty?
      def find(event_id) = @scope.find_by(id: event_id)&.then { |event| Receipt.new(event) }
    end
  end
end
