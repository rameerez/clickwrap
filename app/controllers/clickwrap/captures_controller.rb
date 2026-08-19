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
                                      acting_for: @remediation_represented_party,
                                      **remediation_tenant_option)

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

        # A policy that permits acting for a represented party exists to record
        # WHO was represented. Completing it on the bare engine screen with no
        # represented party would write permanent evidence whose statements
        # assert representative authority over nobody — orphan evidence that
        # reads as more than it is. Those policies arrive here only through a
        # signed remediation route that carries the represented party.
        if @policy.authority_rule.present?
          raise RemediationInvalid,
                "This policy records representative authority, so it needs a signed remediation " \
                "route naming the represented party. It cannot be completed standalone."
        end

        @remediation_token = nil
        @remediation_subject = nil
        @remediation_represented_party = nil
        @remediation_tenant = nil
        return
      end

      @remediation_context = resolve_clickwrap_remediation!(@policy.key, token: token)
      @remediation_token = token
      @remediation_subject = @remediation_context.subject
      @remediation_represented_party = @remediation_context.represented_party
      # The signed token carries the tenant the gate resolved; the engine's own
      # routes have no ambient tenant, so this is the only truthful source.
      @remediation_tenant = @remediation_context.tenant_reference.presence
    end

    def present_policy
      present_clickwrap(
        @policy.key,
        subject: @remediation_subject,
        acting_for: @remediation_represented_party,
        locale: I18n.locale,
        submit_button_text: submit_button_text,
        **remediation_tenant_option
      )
    end

    # Included only when a signed token carried a tenant: a token-less flow
    # keeps the ordinary policy-aware ambient resolution, while a tokened flow
    # must use exactly the tenant the issuing gate resolved and signed.
    def remediation_tenant_option
      @remediation_tenant.nil? ? {} : { tenant: @remediation_tenant }
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
