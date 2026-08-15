# frozen_string_literal: true

module Clickwrap
  # What a host controller gets for free: the submission envelope, the two
  # capture verbs, the authentication description, and the `requires_clickwrap`
  # gate.
  #
  # These are thin on purpose. Every one of them forwards to the same public
  # service API a background job, a console, or a native API endpoint would
  # call; the controller layer only supplies the two things it is the only one
  # holding — the current HTTP request and the parsed submission envelope.
  # Nothing here decides anything about the evidence itself.
  module ControllerHelpers
    extend ActiveSupport::Concern

    included do
      # The view-layer DSL does not exist on ActionController::API, and an
      # API-only host that bundles this gem still loads every controller in
      # production. Guarding keeps such a host bootable; an HTML host gets the
      # helpers. (Same idiom as the sessions gem.)
      helper_method :clickwrap_errors if respond_to?(:helper_method)
    end

    class_methods do
      # The controller gate:
      #
      #   class BillingController < ApplicationController
      #     requires_clickwrap :current_terms, only: :show
      #   end
      #
      # An HTML or Turbo visitor is redirected to the mounted capture screen and
      # returned to where they were going. A JSON/API client gets a structured
      # `clickwrap_required` response with the endpoint that can satisfy it.
      #
      # A gate with nowhere to send people is a dead end, so this refuses to
      # compile without either the engine mounted or an explicit
      # `remediation_path:` the host owns. Everything else in `**options` is
      # passed straight through to `before_action` (`only:`, `except:`, `if:`).
      def requires_clickwrap(policy_key, remediation_path: nil, **before_action_options)
        ControllerHelpers.verify_remediation_is_possible!(
          policy_key,
          remediation_path: remediation_path,
          gate: "#{name || "an anonymous controller"}.requires_clickwrap"
        )

        before_action(**before_action_options) do
          clickwrap_gate!(policy_key, remediation_path: remediation_path)
        end
      end
    end

    class << self
      # The current actor, through the host's configured controller method.
      # Shared by the host-facing helper and the engine's own controllers so
      # there is exactly one answer to "who is acting" in the whole web layer.
      def resolve_current_actor(controller)
        method_name = Clickwrap.config.current_actor_method_name

        unless controller.respond_to?(method_name, true)
          raise ConfigurationError,
                "Clickwrap can't find ##{method_name} on #{controller.class.name}. Set " \
                "`config.current_actor_method_name` in config/initializers/clickwrap.rb to the " \
                "controller method that returns the signed-in " \
                "#{Clickwrap.config.actor_class_name} (:current_user by default, which is what " \
                "Devise and the Rails authentication generator both provide)."
        end

        controller.send(method_name)
      end

      # Whether a required gate has somewhere to send someone who has not
      # completed the policy yet.
      #
      # This is checked when the gate is declared, which in a booted application
      # is usually after the host's routes are drawn — but not always. Rails
      # eager-loads controllers (`:eager_load!`) BEFORE it loads the route set
      # (`:set_routes_reloader_hook`), so in production the class body of a
      # gated controller can run while `Rails.application.routes` is still
      # empty. Rails 7.1 added `reload_routes_unless_loaded` for exactly this
      # situation; when it is unavailable or fails for a reason of the host's
      # own, we defer rather than guess, and the same check runs again on the
      # first request the gate handles. Either way the developer gets the same
      # sentence — never a silent dead end.
      def verify_remediation_is_possible!(policy_key, remediation_path:, gate:)
        return true if remediation_path
        return true unless defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application
        return true if load_host_routes == :unavailable

        # Only a success is remembered, and only to keep a gated request from
        # rescanning the route set every time. A mount that later disappears
        # would surface as an ordinary routing error, which is loud enough.
        return true if verified_gates.include?(policy_key.to_s)

        if engine_is_mounted?
          verified_gates << policy_key.to_s
          return true
        end

        raise ConfigurationError,
              "#{gate} :#{policy_key} would have no way to be satisfied. A required gate needs " \
              "somewhere to send the person it stops, and Clickwrap::Engine is not mounted, so " \
              "there is no capture screen to redirect them to. Either mount it:\n\n" \
              "  mount Clickwrap::Engine => \"/agreements\"\n\n" \
              "or point this gate at a page you own:\n\n" \
              "  requires_clickwrap :#{policy_key}, remediation_path: \"/support/agreements\"\n\n" \
              "A gate that blocks an action with no route to unblocking it is a dead end, and " \
              "Clickwrap will not compile one."
      end

      def engine_is_mounted?
        ::Rails.application.routes.routes.any? { |route| mounts_clickwrap_engine?(route) }
      rescue StandardError
        false
      end

      def verified_gates
        @verified_gates ||= Set.new
      end

      private

      def load_host_routes
        return :loaded if ::Rails.application.routes.routes.any?
        return :unavailable unless ::Rails.application.respond_to?(:reload_routes_unless_loaded)

        ::Rails.application.reload_routes_unless_loaded
        :loaded
      rescue StandardError
        :unavailable
      end

      # `mount Clickwrap::Engine => "/agreements"` stores the engine behind a
      # constraints wrapper, and a host is free to rename the mount with `as:`,
      # so the reliable question is "does any route dispatch to this engine",
      # not "does a particular URL helper exist".
      def mounts_clickwrap_engine?(route)
        target = route.app
        candidates = [target]
        candidates << target.app if target.respond_to?(:app)

        candidates.any? { |candidate| candidate == Clickwrap::Engine || candidate.is_a?(Clickwrap::Engine) }
      rescue StandardError
        false
      end
    end

    # The submission envelope this request carried: a signed presentation token
    # and the answers the manifest declared. Memoized because reading it twice
    # in one action should not parse it twice.
    def clickwrap_submission
      @clickwrap_submission ||= Submission.from_params(params)
    end

    # Server-side validation errors from the last capture attempt in this
    # request, keyed by statement. The reference views read this to re-render a
    # failed submission with the message beside the control it belongs to, with
    # no JavaScript involved.
    def clickwrap_errors
      @clickwrap_errors ||= {}
    end

    # `Clickwrap.capture!` with the two things only a controller has.
    def capture_clickwrap!(policy_key, **options)
      Clickwrap.capture!(policy_key, **clickwrap_capture_options(options))
    end

    # `Clickwrap.capture_and!` with the same defaults. The block runs inside the
    # same database transaction as the evidence write: if either fails, neither
    # happened.
    def capture_clickwrap_and!(policy_key, **options, &block)
      Clickwrap.capture_and!(policy_key, **clickwrap_capture_options(options), &block)
    end

    # Whatever the host chose to record about how this request was
    # authenticated. Clickwrap does not inspect the session itself: what counts
    # as an authentication context is the host's decision, and the default is an
    # empty hash rather than a guess.
    def clickwrap_authentication_context
      Clickwrap.config.describe_authentication_with.call(self)
    end

    private

    def clickwrap_current_actor
      @clickwrap_current_actor ||= ControllerHelpers.resolve_current_actor(self)
    end

    def clickwrap_current_tenant
      Clickwrap.config.find_current_tenant_with.call(self)
    end

    def clickwrap_capture_options(options)
      resolved = options.dup
      resolved[:http_request] = request unless resolved.key?(:http_request)
      resolved[:submission] = clickwrap_submission unless resolved.key?(:submission)
      resolved[:actor] = clickwrap_current_actor unless resolved.key?(:actor)
      resolved[:tenant] = clickwrap_current_tenant unless resolved.key?(:tenant)
      resolved
    end

    # The gate itself. It answers the question "is this actor current for this
    # policy" through the ordinary public verification API — the same one a
    # service object at the domain boundary would call — and remediates when the
    # answer is no.
    #
    # Controller gates improve the flow. They are not the security boundary:
    # anything consequential should still call `Clickwrap.require!` where the
    # action actually happens.
    def clickwrap_gate!(policy_key, remediation_path: nil)
      ControllerHelpers.verify_remediation_is_possible!(
        policy_key,
        remediation_path: remediation_path,
        gate: "#{self.class.name}.requires_clickwrap"
      )

      actor = clickwrap_current_actor
      return if actor && Clickwrap.current?(policy_key, actor: actor, tenant: clickwrap_current_tenant)

      clickwrap_require_remediation(policy_key, remediation_path: remediation_path)
    end

    def clickwrap_require_remediation(policy_key, remediation_path:)
      destination = remediation_path || clickwrap_capture_url_for(policy_key)

      if clickwrap_prefers_a_structured_response?
        render json: {
                 error: "clickwrap_required",
                 policy: policy_key.to_s,
                 presentation_url: destination
               },
               status: :forbidden
      else
        redirect_to clickwrap_return_to_destination(destination), allow_other_host: false
      end
    end

    def clickwrap_capture_url_for(policy_key)
      clickwrap_engine_routes.capture_path(policy_key)
    end

    # The mounted proxy when the host mounted the engine (it carries the mount
    # prefix), the engine's own prefix-less helpers otherwise.
    def clickwrap_engine_routes
      respond_to?(:clickwrap) ? clickwrap : Clickwrap::Engine.routes.url_helpers
    end

    # Where to come back to once the policy is satisfied. Only this request's
    # own path travels — never a client-supplied URL — so the gate cannot be
    # turned into an open redirect.
    def clickwrap_return_to_destination(destination)
      separator = destination.include?("?") ? "&" : "?"
      "#{destination}#{separator}return_to=#{CGI.escape(request.fullpath)}"
    end

    # HTML and Turbo get a redirect they can follow; everything else gets a
    # response it can branch on. An API-only controller never has an HTML
    # rendering path, so it always gets the structured form.
    def clickwrap_prefers_a_structured_response?
      return true if defined?(::ActionController::API) && is_a?(::ActionController::API)
      return true if request.format.json?

      symbol = request.format.symbol.to_s
      !(request.format.html? || symbol.include?("turbo"))
    end
  end
end
