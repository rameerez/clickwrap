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
    #
    # What it renders, by default, is ONE line:
    #
    #   [ ] I agree to the Terms of Service and I acknowledge the Privacy Policy.
    #
    # …whenever the policy's statements are all ordinary, required,
    # default-worded agreements and acknowledgments. Anything the sentence
    # cannot honestly absorb keeps a control of its own below it, and a policy
    # with nothing composable is untouched. `combined: false` asks for the
    # itemized shape regardless — one boolean, no style registry — and it
    # reaches the PRESENTER rather than the template, so the manifest signs the
    # shape that was actually offered.
    def clickwrap(policy_key, submit:, actor: NOT_GIVEN, subject: nil, tenant: NOT_GIVEN,
                  acting_for: nil, locale: nil, capture_channel: nil, errors: nil,
                  combined: true, **html_options)
      clickwrap_reserve_form_presentation!(policy_key)
      text, button_options = clickwrap_split_submit(submit)

      presentation = clickwrap_present(
        policy_key,
        submit_button_text: text,
        actor: actor,
        subject: subject,
        tenant: tenant,
        acting_for: acting_for,
        locale: locale,
        capture_channel: capture_channel,
        combined: combined
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
    #   <%= form.clickwrap_submit %>
    #
    # The manifest records the call to action the person was offered, so the
    # wording is declared here. `form.clickwrap_submit` reuses it without a
    # second string. An ordinary `form.submit "Create account"` is supported too,
    # but Clickwrap verifies that it says exactly what the manifest says.
    #
    # A design system that renders its OWN button markup — not `form.submit`,
    # so not something Clickwrap can check — takes the block form and reads the
    # wording off the presentation instead of retyping it:
    #
    #   <%= form.clickwrap_fields :signup, submit_button_text: "Create account" do |clickwrap| %>
    #     <button class="btn btn--primary" data-turbo-submits-with="Creating…">
    #       <%= clickwrap.submit_button_text %>
    #     </button>
    #   <% end %>
    #
    # The block is yielded the whole Presenter::Result — `submit_button_text`,
    # `statements`, `policy_key`, `locale` — and its output is rendered inside
    # the same wrapper, after the controls. This is the shape that makes drift
    # impossible rather than merely detected: there is one string, it is the
    # signed one, and nothing has to compare two copies of it afterwards.
    #
    # `submit:` on `form.clickwrap` and `submit_button_text:` here are a
    # deliberate pair, not a duplication. `submit:` says "render the button
    # too"; `submit_button_text:` says "bind these exact words into the
    # manifest, and I will render the button myself".
    def clickwrap_fields(policy_key, submit_button_text:, actor: NOT_GIVEN, subject: nil,
                         tenant: NOT_GIVEN, acting_for: nil, locale: nil, capture_channel: nil, errors: nil,
                         combined: true, **html_options, &block)
      clickwrap_reserve_form_presentation!(policy_key)
      presentation = clickwrap_present(
        policy_key,
        submit_button_text: submit_button_text,
        actor: actor,
        subject: subject,
        tenant: tenant,
        acting_for: acting_for,
        locale: locale,
        capture_channel: capture_channel,
        combined: combined
      )

      # A block that renders the action itself has already single-sourced the
      # wording off the signed presentation, so there is no second copy left to
      # verify — and arming the `form.submit` check would then reject a form
      # that never called `form.submit` at all.
      @clickwrap_expected_submit_button_text = presentation.submit_button_text unless block

      clickwrap_render_fields(
        presentation,
        submit: nil,
        errors: errors,
        html_options: html_options,
        after: (@template.capture(presentation, &block) if block)
      )
    end

    # The DRY split-form action. `clickwrap_fields` already declared and signed
    # the exact wording, so this helper renders that same wording without asking
    # the host to repeat it:
    #
    #   <%= form.clickwrap_fields :signup, submit_button_text: "Create account" %>
    #   <%= form.clickwrap_submit class: "button" %>
    #
    # Ordinary `form.submit "Create account"` remains supported and is checked
    # below. This helper simply removes the second string and therefore removes
    # the possibility of drift by construction.
    def clickwrap_submit(**options)
      unless @clickwrap_expected_submit_button_text
        raise ConfigurationError,
              "form.clickwrap_submit needs form.clickwrap_fields earlier in the same form. " \
              "The fields declare the exact call to action that Clickwrap signs into evidence."
      end

      submit(@clickwrap_expected_submit_button_text, options)
    end

    # When a split integration uses Rails' ordinary form.submit, compare the
    # button Rails actually rendered with the words already signed into the
    # presentation, refused in every environment rather than left as a
    # development log. Honest bound: this hook covers `form.submit` — a raw
    # <button> tag, `form.button`, or `submit_tag` bypasses it, which is why
    # the custom-surface helpers exist (`clickwrap_submit_button` words the
    # button FROM the manifest, so there is nothing to drift).
    def submit(value = nil, options = {})
      html = super
      clickwrap_verify_split_submit_button!(html) if @clickwrap_expected_submit_button_text
      html
    end

    private

    def clickwrap_reserve_form_presentation!(policy_key)
      return @clickwrap_policy_rendered_in_this_form = policy_key.to_s if @clickwrap_policy_rendered_in_this_form.nil?

      raise ConfigurationError,
            "One Rails form can submit only one Clickwrap presentation. This form already renders " \
            "#{@clickwrap_policy_rendered_in_this_form.inspect} and tried to render #{policy_key.to_s.inspect}. " \
            "Put the statements in one Clickwrap policy, or use a separate form for each policy, so " \
            "the request carries one unambiguous signed presentation token."
    end

    def clickwrap_present(policy_key, submit_button_text:, actor:, subject:, tenant:, acting_for:,
                          locale:, capture_channel:, combined:)
      options = {
        actor: actor.equal?(NOT_GIVEN) ? clickwrap_actor_from_view_context : actor,
        subject: subject,
        acting_for: acting_for,
        tenant: tenant.equal?(NOT_GIVEN) ? clickwrap_tenant_from_view_context(policy_key) : tenant,
        locale: locale || clickwrap_locale_from_view_context,
        submit_button_text: submit_button_text,
        combined: combined
      }
      controller = @template.try(:controller)
      if controller.respond_to?(:clickwrap_document_version_path_for_presentation, true)
        options[:default_document_version_path_with] = lambda do |version, declared_link|
          controller.send(:clickwrap_document_version_path_for_presentation, version,
                          declared_link: declared_link)
        end
      elsif @template.respond_to?(:clickwrap_document_version_path)
        options[:default_document_version_path_with] = lambda do |version, declared_link|
          declared_link.presence || @template.clickwrap_document_version_path(version)
        end
      end
      if controller.respond_to?(:clickwrap_authentication_context, true)
        options[:authentication_context] = controller.send(:clickwrap_authentication_context)
      end
      options[:capture_channel] = capture_channel if capture_channel

      if acting_for.respond_to?(:new_record?) && acting_for.new_record?
        unless controller.respond_to?(:clickwrap_represented_party_creation_flow_id, true)
          raise ConfigurationError,
                "Creating a represented party with Clickwrap needs a controller session to " \
                "bind the browser flow. Include Clickwrap::ControllerHelpers in the parent controller."
        end

        options[:represented_party_creation_flow_id] =
          controller.send(:clickwrap_represented_party_creation_flow_id, policy_key)
      end

      if options[:actor].nil? && @object.respond_to?(:new_record?) && @object.new_record?
        controller = @template.try(:controller)

        unless controller.respond_to?(:clickwrap_registration_flow_id, true)
          raise ConfigurationError,
                "A signup clickwrap needs a controller session to bind its registration flow. " \
                "Include Clickwrap::ControllerHelpers in the parent controller."
        end

        options[:prospective_actor] = @object
        options[:registration_flow_id] = controller.send(:clickwrap_registration_flow_id, policy_key)
      end

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
    def clickwrap_render_fields(presentation, submit:, errors:, html_options:, after: nil)
      @template.render(
        partial: "clickwrap/shared/fields",
        locals: {
          presentation: presentation,
          submit: submit,
          after: after,
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

    def clickwrap_verify_split_submit_button!(html)
      control = Loofah.fragment(html.to_s).css("input[type='submit'], button[type='submit'], button:not([type])").first
      actual = control&.name == "input" ? control["value"] : control&.text
      expected = @clickwrap_expected_submit_button_text

      unless actual == expected
        raise ConfigurationError,
              "The Clickwrap presentation records #{expected.inspect} as the submit button text, " \
              "but form.submit rendered #{actual.inspect}. Use the same exact words, or call " \
              "form.clickwrap_submit so the signed wording is the only source of truth."
      end

      @clickwrap_expected_submit_button_text = nil
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

    def clickwrap_tenant_from_view_context(policy_key)
      controller = @template.try(:controller)
      return nil if controller.nil?

      ControllerHelpers.resolve_current_tenant(controller, Clickwrap.policy!(policy_key))
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
