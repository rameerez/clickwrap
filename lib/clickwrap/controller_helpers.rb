# frozen_string_literal: true

require "cgi/escape"

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
      if respond_to?(:helper_method)
        helper_method :clickwrap_errors, :present_clickwrap, :clickwrap_document_version_path_for_presentation
      end
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
      def requires_clickwrap(policy_key, remediation_path: nil, subject_with: nil,
                             acting_for_with: nil, **before_action_options)
        ControllerHelpers.validate_gate_resolver!(:subject_with, subject_with)
        ControllerHelpers.validate_gate_resolver!(:acting_for_with, acting_for_with)
        # The dead-end check is REGISTERED here, not run here.
        #
        # Rails eager-loads controllers before it draws the route set, so a
        # class body in production can run while `Rails.application.routes` is
        # still empty — and a check that ran now would fail on a perfectly
        # well-configured application just because it looked too early. So the
        # gate records itself, an `after_initialize` sweep checks every
        # registered gate once the routes exist, and the request path checks
        # again as a backstop for a controller that was autoloaded later.
        #
        # The developer still gets the same sentence at boot. It just comes from
        # a moment when the answer is knowable.
        ControllerHelpers.register_gate(
          policy_key,
          remediation_path: remediation_path,
          subject_with: subject_with,
          acting_for_with: acting_for_with,
          gate: "#{name || "an anonymous controller"}.requires_clickwrap"
        )

        before_action(**before_action_options) do
          clickwrap_gate!(policy_key, remediation_path: remediation_path,
                                      subject_with: subject_with,
                                      acting_for_with: acting_for_with)
        end
      end
    end

    Gate = Data.define(:policy_key, :remediation_path, :subject_with,
                       :acting_for_with, :gate)

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

      # Resolves ambient tenant context through the policy that will bind it.
      # This is shared by form rendering, custom presentations, captures, gates,
      # and remediation tokens so they cannot disagree about whether a current
      # organization belongs in this evidence identity.
      def resolve_current_tenant(controller, policy)
        candidate = Clickwrap.config.find_current_tenant_with.call(controller)
        policy.tenant_from_controller(candidate)
      end

      # Remembers a declared gate so it can be checked once the route set
      # exists. Re-declaring the same gate (a development reload) replaces the
      # entry rather than accumulating duplicates.
      def register_gate(policy_key, remediation_path:, gate:, subject_with: nil,
                        acting_for_with: nil)
        registered_gates[[gate, policy_key.to_s]] = Gate.new(
          policy_key: policy_key.to_s,
          remediation_path: remediation_path,
          subject_with: subject_with,
          acting_for_with: acting_for_with,
          gate: gate
        )
      end

      def registered_gates
        @registered_gates ||= {}
      end

      # Run from the engine's `after_initialize`, when the host's routes are
      # drawn and the answer is actually knowable.
      def verify_registered_gates!
        registered_gates.each_value do |entry|
          verify_remediation_is_possible!(
            entry.policy_key,
            remediation_path: entry.remediation_path,
            subject_with: entry.subject_with,
            acting_for_with: entry.acting_for_with,
            gate: entry.gate
          )
        end
      end

      def verify_remediation_is_possible!(policy_key, remediation_path:, gate:,
                                          subject_with: nil, acting_for_with: nil)
        if subject_with && !Clickwrap.config.remediation_subject_authorization_configured?
          raise ConfigurationError,
                "#{gate} :#{policy_key} resolves a subject with `subject_with:`, but the host " \
                "has not configured `authorize_clickwrap_remediation_subject_with`. That " \
                "server-side callback must decide whether the current actor may complete this " \
                "policy for the resolved subject."
        end

        if acting_for_with && !Clickwrap.config.remediation_represented_party_authorization_configured?
          raise ConfigurationError,
                "#{gate} :#{policy_key} resolves a represented party with `acting_for_with:`, " \
                "but the host has not configured " \
                "`authorize_clickwrap_remediation_represented_party_with`."
        end

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
              "there is no capture screen to redirect them to. Either mount it:\n\n  " \
              "mount Clickwrap::Engine => \"/agreements\"\n\n" \
              "or point this gate at a page you own:\n\n  " \
              "requires_clickwrap :#{policy_key}, remediation_path: \"/support/agreements\"\n\n" \
              "A gate that blocks an action with no route to unblocking it is a dead end, and " \
              "Clickwrap will not compile one."
      end

      # Rails names a mounted engine's URL-helper proxy after the engine's
      # railtie name, so `mounted_helpers` defining `clickwrap` is the same fact
      # as "this application mounted us" — and it is a fact Rails maintains
      # rather than one inferred by walking route objects, whose wrapping has
      # changed shape more than once across versions. The route scan stays as a
      # second opinion for anything unusual.
      def engine_is_mounted?
        helpers = ::Rails.application.routes.mounted_helpers
        return true if helpers&.method_defined?(:clickwrap)

        ::Rails.application.routes.routes.any? { |route| mounts_clickwrap_engine?(route) }
      rescue StandardError
        false
      end

      def verified_gates
        @verified_gates ||= Set.new
      end

      def validate_gate_resolver!(name, resolver)
        return if resolver.nil? || resolver.is_a?(Symbol) || resolver.respond_to?(:call)

        raise ConfigurationError,
              "#{name} must be a controller method name (Symbol) or a callable, got #{resolver.inspect}."
      end

      private

      def load_host_routes
        return :loaded if ::Rails.application.routes.routes.any?
        return :unavailable unless ::Rails.application.respond_to?(:reload_routes_unless_loaded)

        ::Rails.application.reload_routes_unless_loaded

        # Asking is not the same as getting. From Rails 7.2 on,
        # `reload_routes_unless_loaded` is a no-op until the application has
        # finished initializing — and every moment a gate is checked at boot
        # (an eager-loaded class body, `after_initialize`) is before that, because
        # `:set_routes_reloader_hook` runs last. Reporting `:loaded` there would
        # tell a host that mounts the engine that the engine is not mounted, and
        # refuse to boot over it. So report what is actually there and let the
        # check defer to the first request, exactly as documented above.
        ::Rails.application.routes.routes.any? ? :loaded : :unavailable
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
      Clickwrap.capture!(policy_key, **clickwrap_capture_options(policy_key, options))
    end

    # `Clickwrap.capture_and!` with the same defaults. The block runs inside the
    # same database transaction as the evidence write: if either fails, neither
    # happened.
    def capture_clickwrap_and!(policy_key, **options, &)
      Clickwrap.capture_and!(policy_key, **clickwrap_capture_options(policy_key, options), &)
    end

    # `Clickwrap.present` with the same actor, tenant, and locale defaults the
    # controller capture helpers use. Custom views should call this instead of
    # manually repeating ambient context, which keeps GET and POST binding
    # identical by construction.
    def present_clickwrap(policy_key, **options)
      resolved = options.dup
      resolved[:actor] = clickwrap_current_actor unless resolved.key?(:actor)
      resolved[:tenant] = clickwrap_current_tenant(policy_key) unless resolved.key?(:tenant)
      resolved[:locale] = I18n.locale unless resolved.key?(:locale)
      resolved[:document_version_path_with] ||= method(:clickwrap_document_version_path_for_presentation)

      Clickwrap.present(policy_key, **resolved)
    end

    # The exact immutable URL offered beside a Clickwrap control. The mounted
    # engine route is the default. A host that needs a native-app external-link
    # wrapper or another reviewed routing layer can override this one method;
    # the resulting path is both rendered and signed into the presentation
    # manifest, so the evidence never claims a different target from the link.
    def clickwrap_document_version_path_for_presentation(version)
      clickwrap_engine_routes.document_version_path(version.id)
    end

    # Signup, for Rails' own authentication generator or any hand-rolled
    # registration:
    #
    #   register_with_clickwrap :signup, user: @user do
    #     @user.save!
    #   end
    #
    # The account and the evidence that authorized creating it commit together.
    # A failed evidence write raises rather than returning falsy, so the sign-in,
    # the welcome email, and the redirect that would normally follow simply do
    # not happen — which is the difference between a refused signup and a live
    # account nobody can explain.
    def register_with_clickwrap(policy_key, user: nil, prospective_actor: nil, **, &)
      result = Clickwrap::Registration.perform(
        policy_key,
        prospective_actor: prospective_actor || user,
        http_request: request,
        submission: clickwrap_submission,
        tenant: clickwrap_current_tenant(policy_key),
        registration_flow_id: clickwrap_registration_flow_id(policy_key),
        **,
        &
      )

      clear_clickwrap_registration_flow_when_committed(result, policy_key)
      result
    end

    # Whatever the host chose to record about how this request was
    # authenticated. Clickwrap does not inspect the session itself: what counts
    # as an authentication context is the host's decision, and the default is an
    # empty hash rather than a guess.
    def clickwrap_authentication_context
      Clickwrap.config.describe_authentication_with.call(self)
    end

    # Resolves and re-authorizes the signed context handed to a custom
    # `remediation_path:`. The returned object exposes `subject`,
    # `represented_party`, and `return_to`; pass the first two to both
    # presentation and capture. No browser-owned id needs to be permitted.
    def resolve_clickwrap_remediation!(policy_key, token: params[:remediation_token])
      context = RemediationToken.resolve!(
        token,
        policy: Clickwrap.policy!(policy_key),
        actor: clickwrap_current_actor,
        tenant: clickwrap_current_tenant(policy_key)
      )

      authorize_clickwrap_remediation_context!(
        policy_key,
        actor: clickwrap_current_actor,
        subject: context.subject,
        represented_party: context.represented_party
      )
      context
    end

    private

    def clickwrap_registration_flow_id(policy_key)
      unless respond_to?(:session)
        raise ConfigurationError,
              "Registration-flow binding needs a controller session. API registrations must " \
              "create their own server-side registration_flow_id and pass it to both " \
              "Clickwrap.present and Clickwrap.register!."
      end

      flows = (session[:clickwrap_registration_flows] ||= {})
      flows[policy_key.to_s] ||= SecureRandom.uuid
    end

    def clear_clickwrap_registration_flow_id(policy_key)
      session[:clickwrap_registration_flows]&.delete(policy_key.to_s)
    end

    def clear_clickwrap_registration_flow_when_committed(result, policy_key)
      if result.respond_to?(:when_durably_committed)
        result.when_durably_committed { clear_clickwrap_registration_flow_id(policy_key) }
      elsif result.committed?
        clear_clickwrap_registration_flow_id(policy_key)
      end
    end

    def clickwrap_current_actor
      @clickwrap_current_actor ||= ControllerHelpers.resolve_current_actor(self)
    end

    def clickwrap_current_tenant(policy_key = nil)
      return Clickwrap.config.find_current_tenant_with.call(self) if policy_key.nil?

      ControllerHelpers.resolve_current_tenant(self, Clickwrap.policy!(policy_key))
    end

    def clickwrap_capture_options(policy_key, options)
      resolved = options.dup
      resolved[:http_request] = request unless resolved.key?(:http_request)
      resolved[:submission] = clickwrap_submission unless resolved.key?(:submission)
      resolved[:actor] = clickwrap_current_actor unless resolved.key?(:actor)
      resolved[:tenant] = clickwrap_current_tenant(policy_key) unless resolved.key?(:tenant)
      resolved[:authentication_context] = clickwrap_authentication_context unless
        resolved.key?(:authentication_context)
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
    def clickwrap_gate!(policy_key, remediation_path: nil, subject_with: nil, acting_for_with: nil)
      # A gate inherited from the host's ApplicationController must never gate
      # Clickwrap's own remediation, receipt, withdrawal, or document screens.
      # Those screens are how the person satisfies the gate; redirecting them
      # back to themselves creates a loop and can make the document they must
      # review unreachable. Domain enforcement remains the host's
      # `Clickwrap.require!` call, not this navigation convenience.
      return if clickwrap_engine_controller?

      ControllerHelpers.verify_remediation_is_possible!(
        policy_key,
        remediation_path: remediation_path,
        subject_with: subject_with,
        acting_for_with: acting_for_with,
        gate: "#{self.class.name}.requires_clickwrap"
      )

      actor = clickwrap_current_actor
      unless actor
        if clickwrap_prefers_a_structured_response?
          render json: { error: "clickwrap_actor_required", policy: policy_key.to_s }, status: :unauthorized
        else
          head :unauthorized
        end
        return
      end

      subject = resolve_clickwrap_gate_value(subject_with)
      represented_party = resolve_clickwrap_gate_value(acting_for_with)
      tenant = clickwrap_current_tenant(policy_key)

      return if Clickwrap.current?(policy_key, actor: actor, tenant: tenant, subject: subject,
                                               acting_for: represented_party)

      authorize_clickwrap_remediation_context!(policy_key, actor: actor, subject: subject,
                                                           represented_party: represented_party)
      clickwrap_require_remediation(
        policy_key,
        remediation_path: remediation_path,
        actor: actor,
        tenant: tenant,
        subject: subject,
        represented_party: represented_party
      )
    rescue RemediationNotAuthorized
      # A denial must not disclose that the resolved subject or represented
      # party exists. This is the same not-found posture the standalone screen
      # uses for a swapped, expired, or otherwise invalid signed handoff.
      head :not_found
    end

    def clickwrap_require_remediation(policy_key, remediation_path:, actor:, tenant:, subject:,
                                      represented_party:)
      destination = remediation_path || clickwrap_capture_url_for(policy_key)
      token = RemediationToken.issue(
        policy: Clickwrap.policy!(policy_key),
        actor: actor,
        tenant: tenant,
        subject: subject,
        represented_party: represented_party,
        return_to: request.fullpath
      )
      destination = clickwrap_remediation_destination(destination, token)

      if clickwrap_prefers_a_structured_response?
        render json: {
                 error: "clickwrap_required",
                 policy: policy_key.to_s,
                 presentation_url: destination
               },
               status: :forbidden
      else
        redirect_to destination, allow_other_host: false
      end
    end

    def clickwrap_capture_url_for(policy_key)
      clickwrap_engine_routes.capture_path(policy_key)
    end

    def clickwrap_engine_controller?
      defined?(Clickwrap::ApplicationController) && is_a?(Clickwrap::ApplicationController)
    end

    # The mounted proxy when the host mounted the engine (it carries the mount
    # prefix), the engine's own prefix-less helpers otherwise.
    def clickwrap_engine_routes
      respond_to?(:clickwrap) ? clickwrap : Clickwrap::Engine.routes.url_helpers
    end

    # Where to come back to once the policy is satisfied. Only this request's
    # own path travels — never a client-supplied URL — so the gate cannot be
    # turned into an open redirect.
    def clickwrap_remediation_destination(destination, token)
      separator = destination.include?("?") ? "&" : "?"
      "#{destination}#{separator}remediation_token=#{CGI.escape(token)}"
    end

    def resolve_clickwrap_gate_value(resolver)
      return nil if resolver.nil?
      return send(resolver) if resolver.is_a?(Symbol)
      return instance_exec(&resolver) if resolver.arity.zero?

      resolver.call(self)
    end

    def authorize_clickwrap_remediation_context!(policy_key, actor:, subject:, represented_party:)
      policy = Clickwrap.policy!(policy_key)
      subject_allowed = Clickwrap.config.authorize_clickwrap_remediation_subject_with.call(
        actor: actor, subject: subject, policy: policy, controller: self
      )
      party_allowed = Clickwrap.config.authorize_clickwrap_remediation_represented_party_with.call(
        actor: actor, represented_party: represented_party, policy: policy, controller: self
      )
      return true if subject_allowed == true && party_allowed == true

      raise RemediationNotAuthorized,
            "The host did not authorize this actor to remediate the policy for the resolved context."
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
