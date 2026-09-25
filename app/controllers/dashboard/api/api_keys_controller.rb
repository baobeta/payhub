# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    # M-10..M-13. Keys belong to the live merchant and carry livemode; the
    # list shows the keys of the session's current mode.
    class ApiKeysController < BaseController
      requires_permission "api_keys.read", only: :index
      requires_permission "api_keys.manage", only: %i[create roll revoke]

      def index
        keys = keys_in_mode.includes(:created_by).order(created_at: :desc)
        render json: { "data" => keys.map { |k| ApiKeySerializer.call(k) } }
      end

      def create
        key, raw = ApiKey.issue!(merchant: live_merchant, livemode: current_session.livemode,
                                 name: params.require(:name).to_s, note: params[:note].presence&.to_s,
                                 created_by_id: current_user.id)
        audit!("api_key.created", target: key, metadata: { "name" => key.name })
        render json: ApiKeySerializer.call(key).merge("secret" => raw), status: :created # shown once
      end

      def roll
        key = keys_in_mode.find(params[:id])
        expires_in = params.require(:expires_in).to_s
        overlap = ApiKey::ROLL_OVERLAPS.fetch(expires_in) do
          raise ApiError.validation("expires_in" => ["must be one of #{ApiKey::ROLL_OVERLAPS.keys.join(', ')}"])
        end
        replacement, raw = key.roll!(overlap:, by: current_user)
        audit!("api_key.rolled", target: key, metadata: { "replacement_id" => replacement.id, "expires_in" => expires_in })
        render json: ApiKeySerializer.call(replacement).merge("secret" => raw), status: :created
      end

      def revoke
        key = keys_in_mode.find(params[:id])
        key.revoke!
        audit!("api_key.revoked", target: key)
        render json: ApiKeySerializer.call(key)
      end

      private

      def keys_in_mode = live_merchant.api_keys.where(livemode: current_session.livemode)
    end
  end
end
