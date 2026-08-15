# frozen_string_literal: true

module Clickwrap
  # What `has_clickwraps` mixes into the actor model.
  #
  # It adds the evidence proxy and the associations, and nothing else. Notably
  # absent: any `dependent: :destroy`. Deleting an account must not silently
  # erase the record of what that person agreed to — that is a retention
  # decision, and it belongs to the host and its counsel, not to a foreign key.
  #
  # So the associations nullify the actor link on destroy and leave the stable
  # pseudonymous `actor_reference` behind. The evidence remains queryable and
  # verifiable; what disappears is the pointer to a row that no longer exists.
  # A host that genuinely wants the evidence gone runs disposition through
  # `Clickwrap::Privacy`, which records that it did.
  module HasClickwraps
    extend ActiveSupport::Concern

    included do
      has_many :clickwrap_events,
               class_name: "Clickwrap::Event",
               as: :actor,
               inverse_of: :actor,
               dependent: :nullify

      has_many :clickwrap_statement_states,
               class_name: "Clickwrap::StatementState",
               as: :actor,
               inverse_of: :actor,
               dependent: :nullify

      has_many :clickwrap_presentations,
               class_name: "Clickwrap::Presentation",
               as: :actor,
               inverse_of: :actor,
               dependent: :nullify
    end

    # The everyday API: `user.clickwraps.agreed_to?(:terms)`.
    def clickwraps
      @clickwraps ||= Clickwrap::ActorProxy.new(self)
    end

    # How this record is referenced in evidence.
    #
    # A GlobalID by default, because it stays meaningful after the row it points
    # at is gone — which is the situation this reference exists for. Override it
    # when the host has its own stable pseudonymous identifier scheme; the
    # configured `identify_actor_with` asks for this method first, so overriding
    # it here is enough and no initializer change is needed.
    def clickwrap_actor_reference
      to_gid.to_s
    end
  end
end
