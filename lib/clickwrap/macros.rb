# frozen_string_literal: true

module Clickwrap
  # The host-facing macro. The engine extends `ActiveRecord::Base` with this
  # module (via `ActiveSupport.on_load(:active_record)`), so the actor model can
  # declare:
  #
  #   class User < ApplicationRecord
  #     has_clickwraps
  #   end
  #
  # That gives the model its evidence proxy — `user.clickwraps.agreed_to?(:terms)`
  # and friends — plus the associations, without Clickwrap reaching into the
  # model for anything else. Same grammar as the rest of the ecosystem:
  # `has_sessions`, `has_credits`, `has_api_keys`, `has_wallets`.
  #
  # Note what the macro deliberately does NOT add: a `dependent: :destroy` on
  # the evidence association. Deleting an account must not silently erase the
  # record of what that person agreed to; the associations nullify the actor
  # link and leave a stable pseudonymous reference behind, and what happens next
  # is a retention decision the host makes on purpose.
  #
  # The macro is a thin forwarder — all behavior lives in Clickwrap::HasClickwraps
  # so it is discoverable, testable, and `include`-able directly when a host
  # prefers that style.
  #
  # We don't `require_relative` the concern here even though this file is
  # required by the spine at gem-load time. The concern lives under
  # `lib/clickwrap/models/concerns/` and is autoloaded by Zeitwerk (the engine
  # pushes that subtree under the `Clickwrap` namespace with `models` and
  # `concerns` collapsed). Requiring it here too would double-manage the same
  # constant and make Zeitwerk raise on its eager-load pass. This is safe
  # because the macro body only REFERENCES the constant, and it runs when a host
  # model calls `has_clickwraps` — long after boot, when the autoloader is
  # fully wired.
  module Macros
    def has_clickwraps
      include Clickwrap::HasClickwraps unless include?(Clickwrap::HasClickwraps)
      self
    end
  end
end
