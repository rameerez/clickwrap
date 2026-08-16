# frozen_string_literal: true

module Clickwrap
  # Withdrawing one consent purpose.
  #
  # This screen is deliberately as short as the screen that granted the consent
  # in the first place: one page, one control, one press. Withdrawal must be no
  # harder than granting was — no support ticket, no email, no re-authentication
  # the grant did not require, no confirmation maze. A gem that made taking
  # consent back harder than giving it would be building the exact pattern it
  # exists to prevent, so this controller has nothing in it but the two actions.
  #
  # Withdrawal APPENDS an event. It never deletes or edits the historical grant:
  # what was true then stays recorded, and what is true now is that the person
  # changed their mind. Only consent is withdrawable — withdrawing future
  # processing does not rewrite a past agreement or a factual declaration.
  class WithdrawalsController < ApplicationController
    before_action :require_clickwrap_actor
    before_action :find_purpose
    before_action :remember_return_destination

    def new; end

    def create
      Clickwrap.withdraw!(
        @purpose_key,
        actor: clickwrap_current_actor,
        tenant: clickwrap_current_tenant,
        http_request: request,
        because: t("clickwrap.withdrawals.recorded_reason")
      )

      redirect_to @return_to, allow_other_host: false, notice: t("clickwrap.withdrawals.confirmed")
    rescue AlreadyWithdrawnError
      # Pressing the button twice is not an error worth showing a person. The
      # purpose is withdrawn either way, which is what they asked for.
      redirect_to @return_to, allow_other_host: false, notice: t("clickwrap.withdrawals.already_withdrawn")
    rescue NotWithdrawableError => error
      flash.now[:alert] = error.message
      render :new, status: 422
    end

    private

    # The purpose, not the policy: consent is purpose-specific, and a person
    # withdrawing product updates is not withdrawing everything they ever did on
    # the same screen.
    def find_purpose
      @purpose_key = params[:purpose_key].to_s

      head :not_found if @purpose_key.empty?
    end

    # Browser-supplied navigation, checked the same way everywhere: a relative
    # path on this host, or this engine's own root.
    def remember_return_destination
      @return_to = clickwrap_safe_return_to(params[:return_to], fallback: clickwrap_engine_routes.root_path)
    end
  end
end
