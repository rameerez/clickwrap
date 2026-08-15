# frozen_string_literal: true

module Clickwrap
  # The standalone screen for one policy: the same server-owned presentation the
  # form-builder helper renders inline, on a page of its own.
  #
  # This is what stops a required agreement from becoming a dead end. A gate
  # redirects here, the person completes the policy in place, and they are
  # returned to whatever they were trying to do. It is also the screen a host
  # links to directly for a declaration that has expired or a new Terms version
  # that needs accepting.
  class CapturesController < ApplicationController
    before_action :find_policy
    before_action :remember_return_destination

    def show
      @presentation = present_policy
    end

    def create
      capture_clickwrap!(@policy.key)

      redirect_to @return_to, allow_other_host: false, notice: t("clickwrap.captures.recorded")
    rescue AnswerInvalid => error
      re_present_with_error(error.statement_key, t("clickwrap.errors.answer_not_accepted"))
    rescue SubmissionInvalid, PresentationExpired, PresentationInvalid
      # A stale, replayed, or swapped presentation is not something to repair
      # quietly: the server offers the policy again and the person answers the
      # offer they can actually see.
      re_present_with_error(nil, t("clickwrap.errors.presentation_no_longer_valid"))
    end

    private

    def find_policy
      @policy = Clickwrap.policy!(params[:policy_key])
    rescue UnknownPolicyError
      head :not_found
    end

    # Where to go after the policy is satisfied. The gate puts this in the URL
    # and the form carries it through the POST; both are browser-supplied, so
    # both go through the same safety check and fall back to this engine's own
    # root rather than to anywhere interesting.
    def remember_return_destination
      candidate = params[:return_to]
      @return_to = clickwrap_safe_return_to(candidate, fallback: clickwrap_engine_routes.root_path)
    end

    def present_policy
      Clickwrap.present(
        @policy.key,
        actor: clickwrap_current_actor,
        tenant: clickwrap_current_tenant,
        locale: I18n.locale,
        submit_button_text: submit_button_text
      )
    end

    # The words on the button, recorded in the manifest exactly as rendered. A
    # host that wants different words translates the key; there is no way for
    # the rendered button and the recorded text to disagree, because this is the
    # only place either of them comes from.
    def submit_button_text
      t("clickwrap.captures.submit_button_text")
    end

    def re_present_with_error(statement_key, message)
      if statement_key
        clickwrap_errors[statement_key.to_s] = message
      else
        flash.now[:alert] = message
      end

      # A new presentation, not the old one: its nonce is spent, and re-offering
      # a spent token would fail again for a reason that has nothing to do with
      # what the person got wrong.
      @presentation = present_policy
      render :show, status: 422
    end
  end
end
