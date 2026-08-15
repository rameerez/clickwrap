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
    before_action :require_clickwrap_actor
    before_action :load_remediation_context
    before_action :remember_return_destination

    rescue_from RemediationInvalid, with: :remediation_not_found

    def show
      @presentation = present_policy
    end

    def create
      capture_clickwrap!(@policy.key, subject: @remediation_subject,
                                      acting_for: @remediation_represented_party)

      redirect_to @return_to, allow_other_host: false, notice: t("clickwrap.captures.recorded")
    rescue AnswerInvalid => error
      re_present_with_error(error.statement_key, t("clickwrap.errors.answer_not_accepted"))
    rescue SubmissionInvalid, PresentationExpired, PresentationInvalid, ReplayRejected,
           OneTimeAuthorizationConflict
      # A stale, replayed, or swapped presentation is not something to repair
      # quietly: the server offers the policy again and the person answers the
      # offer they can actually see.
      re_present_with_error(nil, t("clickwrap.errors.presentation_no_longer_valid"))
    rescue AuthorityNotVerified
      # Authority is rechecked at submit. A role removed after the page was
      # rendered must not become a 500 or a fresh offer that can never succeed.
      head :forbidden
    rescue RetryableTransactionError
      response.set_header("Retry-After", "1")
      re_present_with_error(nil, t("clickwrap.errors.temporarily_unavailable"), status: :service_unavailable)
    end

    private

    def find_policy
      @policy = Clickwrap.policy!(params[:policy_key])
    rescue UnknownPolicyError
      head :not_found
    end

    def require_clickwrap_actor
      head :unauthorized unless clickwrap_current_actor
    end

    # Where to go after the policy is satisfied. The gate puts this in the URL
    # and the form carries it through the POST; both are browser-supplied, so
    # both go through the same safety check and fall back to this engine's own
    # root rather than to anywhere interesting.
    def remember_return_destination
      candidate = @remediation_context&.return_to || params[:return_to]
      @return_to = clickwrap_safe_return_to(candidate, fallback: clickwrap_engine_routes.root_path)
    end

    def load_remediation_context
      token = params[:remediation_token].presence

      if token.nil?
        if @policy.subject_bound?
          raise RemediationInvalid,
                "This subject-bound policy needs a signed remediation route from the blocked action."
        end

        @remediation_token = nil
        @remediation_subject = nil
        @remediation_represented_party = nil
        return
      end

      @remediation_context = resolve_clickwrap_remediation!(@policy.key, token: token)
      @remediation_token = token
      @remediation_subject = @remediation_context.subject
      @remediation_represented_party = @remediation_context.represented_party
    end

    def present_policy
      Clickwrap.present(
        @policy.key,
        actor: clickwrap_current_actor,
        tenant: clickwrap_current_tenant,
        subject: @remediation_subject,
        acting_for: @remediation_represented_party,
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

    def re_present_with_error(statement_key, message, status: 422)
      if statement_key
        clickwrap_errors[statement_key.to_s] = message
      else
        flash.now[:alert] = message
      end

      # A new presentation, not the old one: its nonce is spent, and re-offering
      # a spent token would fail again for a reason that has nothing to do with
      # what the person got wrong.
      @presentation = present_policy
      render :show, status: status
    end

    def remediation_not_found
      head :not_found
    end
  end
end
