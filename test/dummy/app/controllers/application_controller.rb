# frozen_string_literal: true

# The dummy host's controller — what Clickwrap::ApplicationController inherits
# from by default (config.parent_controller_class_name). Provides the methods the
# engine's defaults expect via a plain session, so no auth framework is needed to
# test the full request cycle.
class ApplicationController < ActionController::Base
  helper_method :current_user, :current_organization

  def current_user
    @current_user ||= User.find_by(id: session[:user_id])
  end

  def current_organization
    @current_organization ||= Organization.find_by(id: session[:organization_id])
  end
end
