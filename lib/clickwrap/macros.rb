# frozen_string_literal: true

module Clickwrap
  # The host-facing macro. The engine extends `ActiveRecord::Base` with this
  # module (via `ActiveSupport.on_load(:active_record)`), so the actor model can
  # declare:
  #
  #   class User < ApplicationRecord
  #     has_clickwraps
  #   end
  #
  # That gives the model its evidence proxy — `user.clickwraps.agreed_to?(:terms)`
  # and friends — plus the associations, without Clickwrap reaching into the
  # model for anything else. Same grammar as the rest of the ecosystem:
  # `has_sessions`, `has_credits`, `has_api_keys`, `has_wallets`.
  #
  # Note what the macro deliberately does NOT add: a `dependent: :destroy` on
  # the evidence association. Deleting an account must not silently erase the
  # record of what that person agreed to; the associations nullify the actor
  # link and leave a stable pseudonymous reference behind, and what happens next
  # is a retention decision the host makes on purpose.
  #
  # The macro is a thin forwarder — all behavior lives in Clickwrap::HasClickwraps
  # so it is discoverable, testable, and `include`-able directly when a host
  # prefers that style.
  #
  # We don't `require_relative` the concern here even though this file is
  # required by the spine at gem-load time. The concern lives under
  # `lib/clickwrap/models/concerns/` and is autoloaded by Zeitwerk (the engine
  # pushes that subtree under the `Clickwrap` namespace with `models` and
  # `concerns` collapsed). Requiring it here too would double-manage the same
  # constant and make Zeitwerk raise on its eager-load pass. This is safe
  # because the macro body only REFERENCES the constant, and it runs when a host
  # model calls `has_clickwraps` — long after boot, when the autoloader is
  # fully wired.
  module Macros
    def has_clickwraps
      include Clickwrap::HasClickwraps unless include?(Clickwrap::HasClickwraps)
      self
    end

    # For a domain row whose existence was authorized by a clickwrap capture —
    # a withdrawal, a signed declaration, a provisioned contract. Expects a
    # `clickwrap_event_id` column (`bin/rails generate clickwrap:link
    # your_table` writes the migration) and an explicit evidence contract:
    #
    #   has_clickwrap_evidence policy: :withdrawal_authorization,
    #                          statement: :withdrawal,
    #                          actor: :user,
    #                          subject: :self
    #
    # It then reads aloud from either end:
    #
    #   capture_clickwrap_and!(:withdrawal_authorization) do |pending_receipt|
    #     withdrawal.clickwrap_event_id = pending_receipt.event_id
    #     withdrawal.save!
    #   end
    #
    #   withdrawal.clickwrap_event      # the evidence event behind this row
    #   withdrawal.clickwrap_receipt    # its receipt: .verify, .to_canonical_json
    #
    # No database foreign key, deliberately: evidence and domain rows keep
    # independent retention schedules. The model contract is still strict for
    # every new link: it checks the policy, statement, human actor, subject,
    # tenant, and represented party, and it never lets a link be replaced.
    # Rows that predate the gem may remain nil; new rows require evidence by
    # default.
    def has_clickwrap_evidence(policy:, statement:, actor:, subject:, tenant: nil,
                               represented_party: nil, required_for_new_records: true)
      belongs_to :clickwrap_event, class_name: "Clickwrap::Event", optional: true

      class_attribute :clickwrap_evidence_contract, instance_writer: false
      self.clickwrap_evidence_contract = {
        policy: policy.to_s,
        statement: statement.to_s,
        actor: actor,
        subject: subject,
        tenant: tenant,
        represented_party: represented_party,
        required_for_new_records: required_for_new_records == true
      }.freeze

      validate :validate_clickwrap_evidence_is_present_for_new_record
      validate :validate_clickwrap_evidence_link_cannot_be_replaced
      validate :validate_clickwrap_evidence_matches_this_record

      define_method(:clickwrap_receipt) do
        self.class.column_names.include?("clickwrap_event_id") ? clickwrap_event&.receipt : nil
      end

      define_method(:validate_clickwrap_evidence_is_present_for_new_record) do
        # A host may deploy the model macro before the link migration, and old
        # data migrations may load today's model while replaying a schema from
        # before Clickwrap existed. The contract becomes strict as soon as the
        # column exists; before then there is no attribute that could carry the
        # evidence, so the macro must stay inert instead of crashing deploys.
        # Class-level `column_names`, never per-row `has_attribute?`: a partial
        # SELECT must not read as "this row has no evidence contract".
        return unless self.class.column_names.include?("clickwrap_event_id")

        contract = self.class.clickwrap_evidence_contract
        return unless new_record? && contract.fetch(:required_for_new_records)
        return if clickwrap_event_id.present?

        errors.add(
          :clickwrap_event,
          "must be linked inside the Clickwrap protected-action transaction"
        )
      end

      define_method(:validate_clickwrap_evidence_link_cannot_be_replaced) do
        return unless self.class.column_names.include?("clickwrap_event_id")
        return unless persisted? && will_save_change_to_clickwrap_event_id?

        previous_id, next_id = clickwrap_event_id_change_to_be_saved
        return if previous_id.blank? || previous_id == next_id

        errors.add(
          :clickwrap_event,
          "cannot be replaced or removed after it has been linked"
        )
      end

      define_method(:validate_clickwrap_evidence_matches_this_record) do
        return unless self.class.column_names.include?("clickwrap_event_id")

        should_validate = new_record? || will_save_change_to_clickwrap_event_id?
        return unless should_validate && clickwrap_event_id.present?

        event = Clickwrap::Event.find_by(id: clickwrap_event_id)
        unless event
          errors.add(:clickwrap_event, "does not identify an existing Clickwrap event")
          next
        end

        contract = self.class.clickwrap_evidence_contract
        expected_policy = Clickwrap.policy!(contract.fetch(:policy))
        expected_statement = expected_policy.statement!(contract.fetch(:statement))

        mismatches = []
        mismatches << "a capture event" unless event.event_type == "capture"
        mismatches << "policy #{expected_policy.key.inspect}" unless event.policy_key == expected_policy.key

        statement_event = event.statements.find do |candidate|
          candidate.statement_key == expected_statement.key &&
            candidate.action == expected_statement.initial_action
        end
        mismatches << "statement #{expected_statement.key.inspect}" unless statement_event

        expected_actor = clickwrap_evidence_contract_value(contract.fetch(:actor), :actor)
        mismatches << "this record's actor" unless
          event.actor_reference == Clickwrap::Reference.actor(expected_actor)

        expected_subject = clickwrap_evidence_contract_value(contract.fetch(:subject), :subject)
        unless event.subject_key.to_s == Clickwrap::Reference.subject(expected_subject).to_s
          mismatches << "this record's subject"
        end

        expected_tenant = clickwrap_evidence_contract_value(contract.fetch(:tenant), :tenant)
        unless event.tenant_key.to_s == Clickwrap::Reference.tenant(expected_tenant).to_s
          mismatches << "this record's tenant"
        end

        expected_party = clickwrap_evidence_contract_value(
          contract.fetch(:represented_party),
          :represented_party
        )
        unless event.represented_party_reference.to_s ==
               Clickwrap::Reference.represented_party(expected_party).to_s
          mismatches << "this record's represented party"
        end

        next unless mismatches.any?

        errors.add(
          :clickwrap_event,
          "must be #{mismatches.to_sentence}; the supplied event belongs to a different act"
        )
      end

      define_method(:clickwrap_evidence_contract_value) do |resolver, name|
        case resolver
        when :self
          self
        when Symbol, String
          public_send(resolver)
        else
          resolver.respond_to?(:call) ? resolver.call(self) : resolver
        end
      rescue NoMethodError => error
        raise DefinitionError,
              "The `#{name}:` resolver for #{self.class.name}.has_clickwrap_evidence could not " \
              "be called: #{error.message}"
      end

      private :validate_clickwrap_evidence_is_present_for_new_record,
              :validate_clickwrap_evidence_link_cannot_be_replaced,
              :validate_clickwrap_evidence_matches_this_record,
              :clickwrap_evidence_contract_value
      self
    end
  end
end
