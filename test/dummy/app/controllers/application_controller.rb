# frozen_string_literal: true

# The dummy host's controller — what Clickwrap::ApplicationController inherits
# from by default (config.parent_controller_class_name). Provides the methods the
# engine's defaults expect via a plain session, so no auth framework is needed to
# test the full request cycle.
class ApplicationController < ActionController::Base
  protect_from_forgery with: :exception

  class_attribute :require_current_terms_everywhere, default: false

  helper_method :current_user, :current_organization

  # Disabled except in the integration test that proves the natural app-wide
  # gate cannot redirect-loop the engine screens that satisfy it.
  requires_clickwrap :current_terms,
                     if: -> { ApplicationController.require_current_terms_everywhere }

  def current_user
    @current_user ||= User.find_by(id: session[:user_id])
  end

  def current_organization
    @current_organization ||= Organization.find_by(id: session[:organization_id])
  end
end
