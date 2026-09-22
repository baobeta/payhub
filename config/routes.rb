Rails.application.routes.draw do
  get "healthz", to: "health#show"

  # /v1 API routes are added phase by phase.
end
