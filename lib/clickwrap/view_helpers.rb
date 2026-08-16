# frozen_string_literal: true

module Clickwrap
  # View helpers for CUSTOM presentation surfaces — the middle ground between
  # `form.clickwrap` (the one-line happy path) and hand-writing every input
  # against `Clickwrap.present` primitives.
  #
  # A custom surface has to render three things correctly or its captures
  # silently fail at submit: the signed token under the exact envelope name,
  # each control under its statement's declared name and id, and a call to
  # action whose words match the ones the manifest recorded. These helpers own
  # those three contracts; the host owns every class, wrapper, and data
  # attribute around them.
  #
  #   <% preparation = Clickwrap.present(:withdrawal_preparation, actor: current_user,
  #                                      submit_button_text: "He leído todo") %>
  #   <%= clickwrap_presentation_token_field(preparation) %>
  #   <% preparation.statements.each do |statement| %>
  #     <%= clickwrap_statement_check_box(statement, class: "my-checkbox") %>
  #     <%= label_tag statement.control_id, statement.assertion %>
  #   <% end %>
  #   <%= clickwrap_submit_button(preparation, class: "my-button") %>
  module ViewHelpers
    # Host-specific navigation attributes for immutable document links. This
    # helper deliberately lives with the helpers installed into every host
    # view, rather than only in EngineHelper: `form.clickwrap` renders the
    # engine's statement partial inside the host form's view context.
    #
    # The immutable href is evidence-critical and therefore cannot be
    # overridden here. Hosts may only choose how their client opens it (for
    # example, target: "_blank" or data: { turbo: false }).
    #
    # The hook is evaluated IN the rendering view, so a host can answer
    # per-request questions the way it always does — `hotwire_native_app?`
    # being the canonical one: a native WebView usually wants a same-window
    # link its screen rules can route, while the web wants a new tab.
    def clickwrap_document_link_html_options(document = nil)
      raw_options = instance_exec(document, &Clickwrap.config.document_link_html_options_with)
      unless raw_options.is_a?(Hash) || raw_options.is_a?(ActiveSupport::HashWithIndifferentAccess)
        raise ConfigurationError,
              "document_link_html_options_with must return a Hash of HTML attributes."
      end

      options = raw_options.to_h.symbolize_keys
      # Case-insensitive on purpose: HTML lowercases attribute names and keeps
      # the FIRST duplicate, so a smuggled "HREF" would win over the signed
      # immutable path in the rendered link.
      if options.keys.any? { |key| key.to_s.casecmp?("href") }
        raise ConfigurationError,
              "document_link_html_options_with cannot set href. Clickwrap signs the exact " \
              "immutable document path into the presentation manifest; this hook may only " \
              "choose how the client opens that path."
      end

      options
    end

    # The signed presentation token, under the envelope name the capture reads.
    # This is the one hidden field a clickwrap form carries — and the one whose
    # name must never be hand-typed, because a typo here is a form that looks
    # complete and refuses every submission.
    def clickwrap_presentation_token_field(presentation)
      hidden_field_tag "clickwrap_submission[presentation_token]", presentation.token, id: nil
    end

    # One statement's checkbox: declared name and id, initially unchecked
    # (always — a pre-ticked box records the page's default, not the person's
    # action), `required` mirroring the server's own rule as progressive
    # enhancement. Everything in `**options` is yours; pass `checked: true`
    # only when re-rendering a submission the person already made.
    def clickwrap_statement_check_box(statement, checked: false, **options)
      options = { id: statement.control_id }.merge(options)
      options[:required] = true if statement.required? && !options.key?(:required)

      check_box_tag statement.control_name, "1", checked, options
    end

    # One option of a statement rendered as a radio group — the pattern for an
    # answer with more than one presented choice (or an affirmative/negative
    # pair, where the negative submits "0"). All options share the statement's
    # control name; each gets a value-suffixed id for its label.
    def clickwrap_statement_radio_button(statement, value, checked: false, **options)
      options = { id: "#{statement.control_id}_#{value}" }.merge(options)

      radio_button_tag statement.control_name, value, checked, options
    end

    # The call to action, worded by the presentation itself. The manifest
    # recorded `submit_button_text` when the offer was signed; rendering the
    # button from the same object is what makes drift between the recorded
    # words and the pressed words impossible on a custom surface.
    def clickwrap_submit_button(presentation, **)
      submit_tag(presentation.submit_button_text, **)
    end
  end
end
