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

    def current_for?(policy_key, subject: nil, tenant: nil)
      Clickwrap.current?(policy_key, actor: actor, subject: subject, tenant: tenant)
    end

    def required_for?(policy_key, subject: nil, tenant: nil)
      !current_for?(policy_key, subject: subject, tenant: tenant)
    end

    def agreed_to?(statement_key, subject: nil, tenant: nil)
      satisfied?("agreement", statement_key, subject: subject, tenant: tenant)
    end

    def acknowledged?(statement_key, subject: nil, tenant: nil)
      satisfied?("acknowledgment", statement_key, subject: subject, tenant: tenant)
    end

    def consented_to?(purpose_key, subject: nil, tenant: nil)
      state = state_for_purpose(purpose_key, subject: subject, tenant: tenant)
      !state.nil? && state.satisfies?
    end

    def declared?(statement_key, subject: nil, tenant: nil)
      satisfied?("declaration", statement_key, subject: subject, tenant: tenant)
    end

    def attested?(statement_key, subject: nil, tenant: nil)
      satisfied?("attestation", statement_key, subject: subject, tenant: tenant)
    end

    def authorized?(statement_key, subject: nil, tenant: nil)
      satisfied?("authorization", statement_key, subject: subject, tenant: tenant)
    end

    # Deliberately a separate question. An exemption records that no human
    # action occurred, so it can never answer `agreed_to?` — the whole reason to
    # record one is that the difference matters.
    def exempted_from?(policy_key, subject: nil, tenant: nil)
      states(subject: subject, tenant: tenant)
        .for_policy(policy_key)
        .where(state: "exempted")
        .exists?
    end

    # --- Records --------------------------------------------------------------

    def declaration(statement_key, subject: nil, tenant: nil)
      state_for("declaration", statement_key, subject: subject, tenant: tenant)
    end

    def consent(purpose_key, subject: nil, tenant: nil)
      state_for_purpose(purpose_key, subject: subject, tenant: tenant)
    end

    def authorization(statement_key, subject: nil, tenant: nil)
      state_for("authorization", statement_key, subject: subject, tenant: tenant)
    end

    def events
      Event.for_actor(actor_reference).chronological
    end

    def receipts
      ReceiptCollection.new(events.where(event_type: Vocabulary::HUMAN_ACTION_EVENT_TYPES))
    end

    def statement_states = states

    def to_s = "clickwraps for #{actor_reference}"

    private

    def actor_reference
      @actor_reference ||= Clickwrap.config.identify_actor_with.call(actor)
    end

    def states(subject: nil, tenant: nil)
      scope = StatementState.for_actor(actor_reference)
      scope = scope.where(subject_key: StatementState.subject_key_for(subject)) unless subject.nil?
      scope = scope.where(tenant_key: tenant.to_s) unless tenant.nil?
      scope
    end

    def satisfied?(kind, statement_key, subject:, tenant:)
      state = state_for(kind, statement_key, subject: subject, tenant: tenant)
      !state.nil? && state.satisfies?
    end

    def state_for(kind, statement_key, subject:, tenant:)
      states(subject: subject, tenant: tenant)
        .for_statement(statement_key)
        .where(kind: kind)
        .order(effective_at: :desc)
        .first
    end

    def state_for_purpose(purpose_key, subject:, tenant:)
      states(subject: subject, tenant: tenant)
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
