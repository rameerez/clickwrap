# frozen_string_literal: true

Rails.application.routes.draw do
  # Mount the engine the way a real host does: the engine's routes are RELATIVE
  # and the host picks the path. We deliberately mount at "/legal" (NOT the
  # README's "/agreements") to prove the gem hardcodes no prefix — the standalone
  # capture screen then lives at /legal/policies/:policy_key, and the host gets the
  # `clickwrap.` URL-helper proxy the controller and integration tests rely on.
  mount Clickwrap::Engine => "/legal"

  # Test-only session endpoint so integration tests can act as a user without
  # dragging a real auth framework into the dummy.
  post "/test_login", to: "sessions#create", as: :test_login

  resources :withdrawals, only: %i[new create show]

  # A host page behind `requires_clickwrap`, so the gate's redirect (HTML) and
  # its structured `clickwrap_required` response (JSON) are exercised through a
  # real request rather than by calling the private helper.
  get "/billing", to: "billing#show", as: :billing
  get "/withdrawal_reviews/:id", to: "withdrawal_reviews#show", as: :withdrawal_review
  get "/settings/privacy", to: "sessions#home", as: :privacy_settings

  root to: "sessions#home"
end
