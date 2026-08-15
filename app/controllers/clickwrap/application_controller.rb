# frozen_string_literal: true

module Clickwrap
  # Base controller for every engine screen. It inherits from the HOST's
  # controller (`config.parent_controller_class_name`, "::ApplicationController"
  # by default) so the host's layout, helpers, authentication filters, locale
  # switching, and exception handling all apply to these screens for free — the
  # same integration style as the sessions, chats, and api_keys gems.
  #
  # NOTE: the superclass is resolved when this class is AUTOLOADED, which in a
  # booted app happens after initializers have run — so a
  # `config.parent_controller_class_name` set in
  # config/initializers/clickwrap.rb is honored. In development the class
  # reloads on change and picks up configuration changes with it.
  class ApplicationController < Clickwrap.config.parent_controller_class_name.constantize
    # The view-layer DSL (`helper`, `helper_method`, `layout`) does not exist on
    # ActionController::API, and an API-only host that bundles this gem for its
    # model and service APIs still eager-loads this class in production, mounted
    # or not. Guarding keeps such a host bootable; the HTML screens themselves
    # still need a Base-derived parent controller, which is the default.
    helper Clickwrap::EngineHelper if respond_to?(:helper)
    helper_method :clickwrap_current_actor, :clickwrap_errors if respond_to?(:helper_method)

    private

    # The actor these screens belong to, through the host's configured method.
    # A missing method is a configuration mistake explained in a full sentence,
    # not a NoMethodError three frames deep.
    def clickwrap_current_actor
      @clickwrap_current_actor ||= ControllerHelpers.resolve_current_actor(self)
    end

    # The host's authentication filters run INSIDE these engine controllers —
    # that is the entire point of inheriting from the host's parent controller —
    # and those filters reference the HOST's own route helpers
    # (`new_session_path` in the Rails authentication generator, custom
    # redirects in hand-rolled filters), which an isolated engine's route set
    # cannot resolve. Delegating unknown `*_path`/`*_url` calls to `main_app`
    # lets the host's code work in here unmodified. It is the standard engine
    # idiom, and the alternative is asking every host to special-case its own
    # authentication for these four screens.
    def method_missing(method, *args, &block)
      if method.to_s.end_with?("_path", "_url") && main_app.respond_to?(method)
        main_app.public_send(method, *args, &block)
      else
        super
      end
    end

    def respond_to_missing?(method, include_private = false)
      (method.to_s.end_with?("_path", "_url") && main_app.respond_to?(method)) || super
    end

    # A destination this application is willing to send someone back to.
    #
    # Return-to values arrive from the browser, so they are treated as untrusted
    # navigation input: a relative path on this host, or nothing. An absolute
    # URL, a protocol-relative "//evil.example", a scheme, or anything carrying
    # control characters falls back to the default rather than being repaired
    # into something that looks close enough.
    def clickwrap_safe_return_to(candidate, fallback:)
      value = candidate.to_s.strip
      return fallback if value.empty?
      return fallback unless value.start_with?("/")
      return fallback if value.start_with?("//", "/\\")
      return fallback if value.match?(/[[:cntrl:]]/)

      uri = begin
        URI.parse(value)
      rescue URI::InvalidURIError
        nil
      end
      return fallback if uri.nil? || uri.scheme.present? || uri.host.present?

      value
    end
  end
end
