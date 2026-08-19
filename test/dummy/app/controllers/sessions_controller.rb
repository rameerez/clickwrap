# frozen_string_literal: true

# Test-only login: integration tests POST /test_login with a user_id to act as
# that user (see test_helper's `login_as`).
class SessionsController < ApplicationController
  def create
    session[:user_id] = params[:user_id]
    session[:organization_id] = params[:organization_id]
    head :no_content
  end

  def home
    render plain: "dummy host root"
  end
end
