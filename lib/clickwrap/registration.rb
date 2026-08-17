# frozen_string_literal: true

module Clickwrap
  # The authentication adapters: how an account and the evidence that authorized
  # creating it commit together.
  #
  # Both are thin conveniences over `Clickwrap.register!`, and both are
  # deliberately EXPLICIT — a line you write in your controller, not a hidden
  # `after_create` callback and not a monkey patch. That matters because this is
  # the exact place two real applications got it wrong in the same way: the
  # account was already persisted, the evidence write failed, and the exception
  # was rescued. The result was a live account with no record of what its owner
  # had agreed to, and nothing anywhere said so.
  #
  # Signup is also modeled honestly. At first render there is no persisted
  # actor, so the presentation binds to a short-lived registration flow rather
  # than to a fictional authenticated user, and the receipt records
  # `account_registration` attribution instead of implying a session that did
  # not exist.
  module Registration
    # Everything that counts as a REFUSAL of one registration attempt — a
    # person on a stale render, an unticked control, a validation the account
    # failed — as opposed to an infrastructure failure (EventWriteFailed and
    # friends), which is never dressed up as validation and always escapes.
    REFUSALS = [
      Clickwrap::SubmissionInvalid,
      Clickwrap::PresentationInvalid,
      Clickwrap::AnswerInvalid,
      Clickwrap::RegistrationFailed,
      ActiveRecord::RecordInvalid
    ].freeze

    def self.included(base)
      base.extend(ClassMethods)
    end

    # Translates one refusal into the same human sentences everywhere: inline
    # beside the control it belongs to (through the controller's
    # clickwrap_errors) and once on the resource's :base so the page's error
    # rollup announces it. The Devise adapter and the hand-rolled-door helper
    # (`register_with_clickwrap` without the bang) both come through here, so
    # every door in an application refuses in identical language by
    # construction — a door cannot forget a rescue it never writes.
    def self.absorb_refusal(error, resource:, clickwrap_errors:)
      case error
      when Clickwrap::AnswerInvalid
        if error.statement_key.present?
          clickwrap_errors[error.statement_key.to_s] = I18n.t("clickwrap.errors.required_statement")
        end
        resource.errors.add(:base, I18n.t("clickwrap.errors.required_statement")) if resource.errors.empty?
      when Clickwrap::SubmissionInvalid, Clickwrap::PresentationInvalid
        # A missing, stale, expired, or swapped presentation is a person on an
        # old render (or a cached form with no presentation at all) — not an
        # application error, and never a raw 500 in front of a person.
        resource.errors.add(:base, I18n.t("clickwrap.errors.presentation_no_longer_valid")) if resource.errors.empty?
      when Clickwrap::RegistrationFailed, ActiveRecord::RecordInvalid
        resource.errors.add(:base, error.message) if resource.errors.empty?
      else
        raise error
      end

      error
    end

    # The optional Devise controller macro. Nothing happens unless a host calls
    # it, and merely loading Clickwrap never requires Devise.
    module ClassMethods
      # Devise:
      #
      #   class Users::RegistrationsController < Devise::RegistrationsController
      #     clickwraps_registration_with :signup
      #   end
      #
      # Wraps the resource save so the account and its evidence share one
      # transaction. Devise's own `create` action remains the implementation of
      # the flow; Clickwrap decorates only the resource's one `save` call.
      def clickwraps_registration_with(policy_key, **options)
        after_save = options.delete(:after_account_is_saved_inside_transaction)
        unless after_save.nil? || after_save.is_a?(Symbol) || after_save.is_a?(String) ||
               after_save.respond_to?(:call)
          raise DefinitionError,
                "`after_account_is_saved_inside_transaction:` must name a controller method " \
                "or be callable. It receives `account:` and `pending_receipt:`."
        end

        prepend Clickwrap::Registration::DeviseAdapter

        self.clickwrap_registration_policy = policy_key
        self.clickwrap_registration_options = options
        self.clickwrap_after_registration_account_is_saved = after_save
      end
    end

    # The primitive both adapters compose. A host with its own registration
    # service can call this directly and get the same guarantees.
    def self.perform(policy_key, prospective_actor:, http_request: nil, submission: nil,
                     tenant: nil, locale: nil, registration_flow_id: nil, &block)
      raise ArgumentError, "register_with_clickwrap needs a block that persists the account" unless block

      Clickwrap.register!(
        policy_key,
        prospective_actor: prospective_actor,
        http_request: http_request,
        submission: submission,
        tenant: tenant,
        locale: locale,
        registration_flow_id: registration_flow_id,
        &block
      )
    end

    # Devise integration.
    #
    # It overrides exactly one thing — how the resource is saved — and leaves
    # everything else about Devise's registration flow alone. Anything more
    # would be this gem taking ownership of a controller it does not own.
    module DeviseAdapter
      extend ActiveSupport::Concern

      prepended do
        class_attribute :clickwrap_registration_policy, instance_writer: false
        class_attribute :clickwrap_registration_options, instance_writer: false, default: {}
        class_attribute :clickwrap_after_registration_account_is_saved,
                        instance_writer: false,
                        default: nil
      end

      private

      # Devise's public registration action owns all response, sign-in, flash,
      # inactive-account, callback, and block-yield behavior. Its only database
      # decision is `resource.save`. Decorating that one instance method keeps
      # those semantics on Devise's side of the boundary and avoids copying a
      # version-specific controller action into this gem.
      def build_resource(*arguments, **keywords, &)
        super.tap { install_clickwrap_save_on(resource) }
      end

      def install_clickwrap_save_on(resource)
        return if resource.instance_variable_defined?(:@clickwrap_save_installation)

        controller = self
        singleton_class = resource.singleton_class
        original_was_singleton = singleton_class.method_defined?(:save, false)
        original_visibility = method_visibility(singleton_class, :save)

        singleton_class.send(:alias_method, :clickwrap_save_without_evidence, :save)
        singleton_class.send(:remove_method, :save) if original_was_singleton
        resource.instance_variable_set(
          :@clickwrap_save_installation,
          { original_was_singleton: original_was_singleton, original_visibility: original_visibility }
        )

        resource.define_singleton_method(:save) do |*arguments, **keywords, &block|
          controller.send(
            :clickwrap_save_registration_resource,
            self,
            -> { clickwrap_save_without_evidence(*arguments, **keywords, &block) }
          )
        ensure
          controller.send(:restore_registration_resource_save, self)
        end
      end

      def restore_registration_resource_save(resource)
        installation = resource.remove_instance_variable(:@clickwrap_save_installation)
        singleton_class = resource.singleton_class
        singleton_class.send(:remove_method, :save)

        if installation.fetch(:original_was_singleton)
          singleton_class.send(:alias_method, :save, :clickwrap_save_without_evidence)
          singleton_class.send(installation.fetch(:original_visibility), :save)
        end

        singleton_class.send(:remove_method, :clickwrap_save_without_evidence)
      end

      def method_visibility(singleton_class, method_name)
        return :private if singleton_class.private_method_defined?(method_name)
        return :protected if singleton_class.protected_method_defined?(method_name)

        :public
      end

      def clickwrap_save_registration_resource(resource, original_save)
        result = Clickwrap::Registration.perform(
          clickwrap_registration_policy,
          prospective_actor: resource,
          http_request: request,
          submission: clickwrap_submission,
          # Policy-aware on purpose: a signup policy declaring
          # `tenant_is :not_applicable` must not inherit whatever ambient
          # organization happens to be current in the session.
          tenant: clickwrap_current_tenant(clickwrap_registration_policy),
          registration_flow_id: clickwrap_registration_flow_id(clickwrap_registration_policy),
          **clickwrap_registration_options
        ) do |pending_receipt|
          saved = original_save.call
          run_after_registration_account_is_saved(resource, pending_receipt) if saved && resource.persisted?
          saved
        end

        clear_clickwrap_registration_flow_when_committed(result, clickwrap_registration_policy)

        resource.persisted?
      rescue *Clickwrap::Registration::REFUSALS => error
        # The one shared translation of refusals into human sentences —
        # inline beside the control and once on :base — so this adapter and
        # every hand-rolled door refuse in identical language.
        Clickwrap::Registration.absorb_refusal(
          error,
          resource: resource,
          clickwrap_errors: clickwrap_errors
        )
        false
      end

      # No local tenant resolution here: ControllerHelpers#clickwrap_current_tenant
      # (installed on every host controller) is the one policy-aware path. A
      # zero-arity override in this PREPENDED module would shadow it for every
      # call site in the host — the exact bug class this comment guards against.

      def run_after_registration_account_is_saved(account, pending_receipt)
        callback = clickwrap_after_registration_account_is_saved
        return if callback.nil?

        arguments = { account: account, pending_receipt: pending_receipt }
        if callback.respond_to?(:call)
          callback.call(**arguments)
        else
          __send__(callback, **arguments)
        end
      end
    end
  end
end
