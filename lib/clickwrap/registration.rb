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
    def self.included(base)
      base.extend(ClassMethods)
    end

    # The two controller macros. Both are available on every controller; nothing
    # happens unless one is actually called, and neither requires Devise.
    module ClassMethods
      # Devise:
      #
      #   class Users::RegistrationsController < Devise::RegistrationsController
      #     clickwraps_registration_with :signup
      #   end
      #
      # Wraps the resource save so the account and its evidence share one
      # transaction. Devise's own emails, sign-in, and redirects are untouched:
      # they run after `create` returns, which is after the transaction has
      # committed.
      def clickwraps_registration_with(policy_key, **options)
        include Clickwrap::Registration::DeviseAdapter

        self.clickwrap_registration_policy = policy_key
        self.clickwrap_registration_options = options
      end

      # Rails' own authentication generator, or any hand-rolled registration:
      #
      #   register_with_clickwrap :signup, user: @user do
      #     @user.save!
      #   end
      #
      # Available as an instance method through ControllerHelpers; this class
      # method exists so the two integrations read the same way in a controller.
      def register_with_clickwrap(policy_key, **options, &block)
        Clickwrap::Registration.perform(policy_key, **options, &block)
      end
    end

    # The primitive both adapters compose. A host with its own registration
    # service can call this directly and get the same guarantees.
    def self.perform(policy_key, prospective_actor:, http_request: nil, submission: nil,
                     tenant: nil, locale: nil, &block)
      raise ArgumentError, "register_with_clickwrap needs a block that persists the account" unless block

      Clickwrap.register!(
        policy_key,
        prospective_actor: prospective_actor,
        http_request: http_request,
        submission: submission,
        tenant: tenant,
        locale: locale,
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

      included do
        class_attribute :clickwrap_registration_policy, instance_writer: false
        class_attribute :clickwrap_registration_options, instance_writer: false, default: {}
      end

      private

      # Devise calls this from `create`. Returning the resource's persisted
      # state is the whole contract, so a failed evidence write has to surface
      # as a raise rather than as a falsy return: `Clickwrap::EventWriteFailed`
      # reaching the controller is precisely what stops Devise from continuing
      # on to sign the person in and send a confirmation email for an account
      # whose evidence does not exist.
      def clickwrap_save_resource(resource)
        Clickwrap::Registration.perform(
          clickwrap_registration_policy,
          prospective_actor: resource,
          http_request: request,
          submission: clickwrap_submission,
          tenant: clickwrap_current_tenant,
          **clickwrap_registration_options
        ) { resource.save }

        resource.persisted?
      end

      # Devise's RegistrationsController#create calls `resource.save`. Wrapping
      # it here keeps the override to one method and one line of behavior.
      def create
        build_resource(sign_up_params)

        if clickwrap_save_resource(resource)
          super_create_success
        else
          clean_up_passwords(resource)
          set_minimum_password_length if respond_to?(:set_minimum_password_length, true)
          respond_with(resource)
        end
      rescue Clickwrap::PresentationInvalid, Clickwrap::AnswerInvalid => error
        clean_up_passwords(resource)
        resource.errors.add(:base, error.message)
        respond_with(resource)
      end

      def super_create_success
        yield_resource_if_block_given
        if resource.active_for_authentication?
          set_flash_message! :notice, :signed_up
          sign_up(resource_name, resource)
          respond_with resource, location: after_sign_up_path_for(resource)
        else
          set_flash_message! :notice, :"signed_up_but_#{resource.inactive_message}"
          expire_data_after_sign_in!
          respond_with resource, location: after_inactive_sign_up_path_for(resource)
        end
      end

      def yield_resource_if_block_given
        yield resource if block_given?
      end

      def clickwrap_current_tenant
        Clickwrap.config.find_current_tenant_with.call(self)
      end
    end
  end
end
