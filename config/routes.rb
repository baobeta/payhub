# typed: strict
# frozen_string_literal: true

Rails.application.routes.draw do
  get "healthz", to: "health#show"
  get "metrics", to: "metrics#show"

  namespace :v1 do
    resources :payments, only: %i[index create show] do
      member do
        post :capture
        post :cancel
      end
      resources :refunds, only: %i[create]
    end
    get "balance", to: "balances#show"

    # Outbound events (to the merchant) and operator replay from dead-letter.
    resources :events, only: %i[index] do
      post :redeliver, on: :member
    end

    # Inbound from the PSP simulators. No merchant auth; signature-verified per PSP.
    post "webhooks/:psp_name", to: "webhooks#create", constraints: { psp_name: /nordpay|kiripay/ }
  end

  namespace :dashboard do
    namespace :api, defaults: { format: :json } do
      get "me", to: "me#show"
      resource :session, only: %i[create destroy] do
        post :otp
        post :recovery
        post :step_up
      end
      resources :invitations, only: %i[create show], param: :token do
        post :accept, on: :member
      end
      get "otp/setup", to: "otp#setup"
      post "otp/confirm", to: "otp#confirm"
      resource :me, only: [], controller: "me" do
        patch :password
        post :recovery_codes
      end
      put "mode", to: "modes#update"
      get "home", to: "home#show"
      resources :payments, only: %i[index show] do
        get :export, on: :collection
        member do
          post :capture
          post :cancel
        end
        resources :refunds, only: :create
      end
      get "balance", to: "balances#show"
      get "settlements", to: "settlements#index"
      resources :api_keys, only: %i[index create] do
        member do
          post :roll
          post :revoke
        end
      end
      resource :webhook_endpoint, only: %i[show update] do
        post :reveal_secret
        post :roll_secret
      end
      resources :events, only: %i[index show] do
        post :redeliver, on: :member
      end
      resources :members, only: %i[index update destroy]
      post "ownership_transfer", to: "ownership_transfers#create"
      get "security_history", to: "security_history#index"
      get "security_history/export", to: "security_history#export"

      # Keep last in this namespace.
      match "*path", to: "fallback#show", via: :all
    end
  end

  # UI shells: the Vue router owns every path below each prefix (design §1).
  # Keep these LAST so /dashboard/api/* and /ops/api/* routes above them match first.
  get "dashboard(/*path)", to: "dashboard/shell#show", format: false
  get "ops(/*path)", to: "ops/shell#show", format: false
  get "demo(/*path)", to: "demo/shell#show", format: false
end
