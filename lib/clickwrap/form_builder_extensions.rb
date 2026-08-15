# frozen_string_literal: true

module Clickwrap
  # `form.clickwrap` and `form.clickwrap_fields`, mixed into the standard Rails
  # form builder by the engine so the one-line happy path works inside an
  # ordinary `form_with`.
  #
  # Both methods do the same three things: ask the server-owned presenter for a
  # presentation, render the reference partial with it, and put the signed
  # presentation token in the form. The difference is only who renders the
  # submit button.
  #
  # `form.clickwrap` is the recommended one because it renders the controls AND
  # the action as a single presentation. The call to action recorded in the
  # manifest is then, by construction, the words on the button the person can
  # actually press — there is no second place for that string to live and drift.
  #
  # What this helper deliberately never renders is a hidden field carrying a
  # decision the server owns: no IP address, no browser user-agent, no
  # geolocation, no policy version, no document digest, no validity window, no
  # retention rule, no subject binding. All of those are resolved server-side
  # and rechecked at submit. A form field is not a safe place to keep a security
  # decision, and a client that tries to send one gets a loud failure from
  # Clickwrap::Submission rather than a quiet acceptance.
  module FormBuilderExtensions
    # Distinguishes "the caller did not mention this" from "the caller
    # explicitly passed nil". `actor: nil` is a real, meaningful value: it is how
    # a signup form says there is no persisted actor yet.
    NOT_GIVEN = Object.new.freeze
    private_constant :NOT_GIVEN

    # The strongest path, and the one the README leads with:
    #
    #   <%= form.clickwrap :signup, submit: "Create account" %>
    #
    #   <%= form.clickwrap :signup,
    #         actor: current_user,
    #         subject: @organization,
    #         locale: I18n.locale,
    #         submit: {
    #           text: "Create organization",
    #           class: "button button--primary",
    #           data: { turbo_submits_with: "Creating…" }
    #         } %>
    #
    # `submit:` takes a String, or a Hash of `text:` plus any ordinary HTML
    # options for the button. Everything else in `**html_options` decorates the
    # wrapper element, so a design system can hang its own classes on the block.
    def clickwrap(policy_key, submit:, actor: NOT_GIVEN, subject: nil, tenant: NOT_GIVEN,
                  locale: nil, capture_channel: nil, errors: nil, **html_options)
      text, button_options = clickwrap_split_submit(submit)

      presentation = clickwrap_present(
        policy_key,
        submit_button_text: text,
        actor: actor,
        subject: subject,
        tenant: tenant,
        locale: locale,
        capture_channel: capture_channel
      )

      clickwrap_render_fields(
        presentation,
        submit: { text: text, options: button_options },
        errors: errors,
        html_options: html_options
      )
    end

    # The split API, for design systems that render the action somewhere this
    # helper cannot reach:
    #
    #   <%= form.clickwrap_fields :signup, submit_button_text: "Create account" %>
    #   <%= form.submit "Create account" %>
    #
    # Yes, the text is written twice, and yes, that is on purpose. The manifest
    # records the call to action the person was offered, so that string has to
    # be declared somewhere; when the button is rendered elsewhere, declaring it
    # here is what keeps the evidence contract visible in the code review rather
    # than implied. The test and development linters compare the declared text
    # with the rendered submit control and report a mismatch. `form.clickwrap`
    # remains the preferred call precisely because it makes that whole class of
    # drift impossible.
    def clickwrap_fields(policy_key, submit_button_text:, actor: NOT_GIVEN, subject: nil,
                         tenant: NOT_GIVEN, locale: nil, capture_channel: nil, errors: nil,
                         **html_options)
      presentation = clickwrap_present(
        policy_key,
        submit_button_text: submit_button_text,
        actor: actor,
        subject: subject,
        tenant: tenant,
        locale: locale,
        capture_channel: capture_channel
      )

      clickwrap_render_fields(
        presentation,
        submit: nil,
        errors: errors,
        html_options: html_options
      )
    end

    private

    def clickwrap_present(policy_key, submit_button_text:, actor:, subject:, tenant:, locale:,
                          capture_channel:)
      options = {
        actor: actor.equal?(NOT_GIVEN) ? clickwrap_actor_from_view_context : actor,
        subject: subject,
        tenant: tenant.equal?(NOT_GIVEN) ? clickwrap_tenant_from_view_context : tenant,
        locale: locale || clickwrap_locale_from_view_context,
        submit_button_text: submit_button_text
      }
      options[:capture_channel] = capture_channel if capture_channel

      Clickwrap.present(policy_key, **options)
    end

    # Rendered through the view context by partial NAME, never by absolute path,
    # so a host copy at app/views/clickwrap/shared/_fields.html.erb shadows the
    # gem's copy with no configuration at all. That is the whole ejection story:
    #
    #   bin/rails generate clickwrap:views
    #
    # The gem's own file lives at
    # Clickwrap::Engine.root.join("app/views/clickwrap/shared/_fields.html.erb").
    def clickwrap_render_fields(presentation, submit:, errors:, html_options:)
      @template.render(
        partial: "clickwrap/shared/fields",
        locals: {
          presentation: presentation,
          submit: submit,
          errors: errors || clickwrap_errors_from_view_context,
          wrapper_options: html_options
        }
      ).tap do |html|
        Linter.review_rendered_fields(html, presentation: presentation) if Linter.enabled?
      end
    end

    # `submit: "Create account"` and `submit: { text: "…", class: "…" }` are the
    # same thing with different amounts of decoration.
    def clickwrap_split_submit(submit)
      case submit
      when Hash
        options = submit.symbolize_keys
        text = options.delete(:text)

        unless text.is_a?(String) && !text.strip.empty?
          raise ArgumentError,
                "form.clickwrap needs the exact words on the submit button: " \
                "`submit: { text: \"Create account\", class: \"…\" }`. That text is recorded in " \
                "the presentation manifest, so it cannot be inferred."
        end

        [text, options]
      when String, Symbol
        [submit.to_s, {}]
      else
        raise ArgumentError,
              "form.clickwrap needs `submit:` to be the button text, or a hash of `text:` plus " \
              "ordinary HTML options. Got #{submit.inspect}."
      end
    end

    # The signed-in actor, resolved through the host's configured controller
    # method, exactly as the rest of the gem resolves it. A form that has no
    # actor yet (signup) passes `actor: nil` explicitly and gets a
    # prospective-actor presentation instead of a fabricated one.
    def clickwrap_actor_from_view_context
      method_name = Clickwrap.config.current_actor_method_name
      return nil unless @template.respond_to?(method_name, true)

      @template.send(method_name)
    end

    def clickwrap_tenant_from_view_context
      controller = @template.try(:controller)
      return nil if controller.nil?

      Clickwrap.config.find_current_tenant_with.call(controller)
    end

    def clickwrap_locale_from_view_context
      defined?(::I18n) ? ::I18n.locale : nil
    end

    # Server-side validation errors from a failed capture, so a no-JavaScript
    # re-render shows what went wrong beside the control it went wrong on. The
    # controller helper exposes this hash; an unaware host simply gets none.
    def clickwrap_errors_from_view_context
      return {} unless @template.respond_to?(:clickwrap_errors, true)

      @template.send(:clickwrap_errors) || {}
    end
  end
end
