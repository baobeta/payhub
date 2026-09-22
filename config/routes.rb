# typed: strict
# frozen_string_literal: true

Rails.application.routes.draw do
  get "healthz", to: "health#show"

  namespace :v1 do
    resources :payments, only: %i[create show] do
      member do
        post :capture
        post :cancel
      end
      resources :refunds, only: %i[create]
    end
    get "balance", to: "balances#show"
    # Inbound from the PSP simulators. No merchant auth; signature-verified per PSP.
    post "webhooks/:psp_name", to: "webhooks#create", constraints: { psp_name: /nordpay|kiripay/ }
    # index (cursor pagination), events → Phase 6
  end
end
