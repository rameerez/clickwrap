# frozen_string_literal: true

# The engine's own routes, drawn under whatever the host mounted it at:
#
#   mount Clickwrap::Engine => "/agreements"
#
# Four surfaces, and nothing else: complete a policy, read a receipt, withdraw a
# consent, read a document version. They exist so that a required agreement, an
# expired declaration, or a consent someone wants back is resolvable IN PLACE
# instead of turning into a support ticket.
#
# Every screen has BOTH a GET and a form-action path at the same URL. That is
# deliberate: a validation failure re-renders under the address the browser is
# already on, so a no-JavaScript submission, a Turbo Drive visit, and a Hotwire
# Native web screen all stay in the navigation context the host intended,
# instead of landing on a POST-only URL that cannot be reloaded or shared.
Clickwrap::Engine.routes.draw do
  # Policy keys, consent purposes, and document version ids are plain
  # identifiers. Constraining them keeps a path segment from carrying something
  # shaped like a path.
  identifier = %r{[^/.]+}

  get "policies/:policy_key", to: "captures#show", as: :capture,
                              constraints: { policy_key: identifier }
  post "policies/:policy_key", to: "captures#create", as: :capture_submission,
                               constraints: { policy_key: identifier }

  get "consents/:purpose_key/withdrawal", to: "withdrawals#new", as: :withdrawal,
                                          constraints: { purpose_key: identifier }
  post "consents/:purpose_key/withdrawal", to: "withdrawals#create", as: :withdrawal_submission,
                                           constraints: { purpose_key: identifier }

  resources :receipts, only: %i[index show]

  # What every document link in every presentation points at, and what an
  # auditor opens years later: one immutable published version, by id.
  get "documents/:id", to: "document_versions#show", as: :document_version,
                       constraints: { id: identifier }

  root to: "receipts#index"
end
