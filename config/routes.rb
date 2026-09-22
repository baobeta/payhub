# typed: strict
# frozen_string_literal: true

Rails.application.routes.draw do
  get "healthz", to: "health#show"

  namespace :v1 do
    resources :payments, only: %i[create show]
    # capture / cancel / refunds / index → Phase 5
    # webhooks / events              → Phase 6
  end
end
