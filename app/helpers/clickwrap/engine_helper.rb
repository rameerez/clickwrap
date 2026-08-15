# frozen_string_literal: true

module Clickwrap
  # View helpers, available BOTH inside the engine's own views and in the HOST
  # app's views (mixed into ActionView by the hook at the bottom of this file,
  # the same pattern the chats and moderate gems use).
  #
  # Everything here is prefixed `clickwrap_`, because these methods land in
  # every view in the host application and a gem has no business claiming a
  # short name in that namespace.
  module EngineHelper
    # The standalone capture screen for one policy — the remediation route:
    #
    #   <%= link_to "Complete your declaration", clickwrap_capture_path(:driver_declaration) %>
    #
    # Any extra options become query parameters, which is how a caller passes
    # `return_to:` for a flow that should resume where it left off.
    def clickwrap_capture_path(policy_key, **options)
      clickwrap_routes.capture_path(policy_key, **options)
    end

    # A receipt, addressed by the event it belongs to. Takes a receipt, an
    # event, or a bare event id, because all three turn up in host code.
    def clickwrap_receipt_path(receipt, **options)
      clickwrap_routes.receipt_path(clickwrap_event_id_for(receipt), **options)
    end

    # Where someone withdraws one consent purpose. Withdrawal is a first-class
    # screen and not a buried mailto: link, because consent that cannot be
    # withdrawn as easily as it was given is not something this gem will keep
    # calling consent.
    def clickwrap_withdrawal_path(purpose_key, **options)
      clickwrap_routes.withdrawal_path(purpose_key, **options)
    end

    # The exact published bytes of one document version — what the presentation
    # links to, and what an auditor reads later.
    def clickwrap_document_version_path(version, **options)
      identifier = version.respond_to?(:id) ? version.id : version

      clickwrap_routes.document_version_path(identifier, **options)
    end

    # The gem's bundled stylesheet. Called from the engine's own views; hosts
    # that eject and restyle the views simply stop including it.
    def clickwrap_styles
      stylesheet_link_tag "clickwrap", "data-turbo-track": "reload"
    end

    # Engine URL helpers that work from EVERY render context:
    #
    #   * host views: the mounted proxy (`clickwrap.`) carries the mount prefix
    #     baked in at mount time, so URLs come out right;
    #   * engine views during requests: the engine's controllers inherit from
    #     the host's ApplicationController, so the proxy is available there too;
    #   * no mount at all (bare view tests): fall back to the engine's own
    #     url_helpers — prefix-less, but nothing better exists without a mount.
    #
    # NOTE: assumes the default mount name (`mount Clickwrap::Engine => "/x"`
    # auto-names the proxy `clickwrap`). A host mounting with `as: :something`
    # overrides this helper.
    def clickwrap_routes
      respond_to?(:clickwrap) ? clickwrap : Clickwrap::Engine.routes.url_helpers
    end

    # The host application's own routes, reachable from inside this isolated
    # engine's views — where a bare `some_path` would be resolved against the
    # engine's route set and explode.
    def clickwrap_main_routes
      respond_to?(:main_app) ? main_app : Rails.application.routes.url_helpers
    end

    private

    def clickwrap_event_id_for(receipt)
      return receipt.event_id if receipt.respond_to?(:event_id)
      return receipt.id if receipt.respond_to?(:id)

      receipt
    end
  end
end

# Expose the helpers to the HOST app's views (isolated engines don't share
# helpers automatically). The hook lives HERE, at the bottom of the file that
# defines the constant — not in an engine initializer — so it's self-resolving:
# whenever this file loads (eager load, autoload on first use, or the engine's
# to_prepare touch), the constant already exists by the time the hook can
# possibly run. Registering it from an initializer instead would blow up at boot
# in hosts where ActionView is already loaded during initializers (web-console
# does this), because `include Clickwrap::EngineHelper` would fire before the
# autoloader is ready.
if defined?(ActiveSupport)
  ActiveSupport.on_load(:action_view) do
    include Clickwrap::EngineHelper
  end
end
