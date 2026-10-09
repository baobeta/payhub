# typed: true
# frozen_string_literal: true

module Ops
  module Api
    # O-12: an operator views a merchant's live dashboard read-only for 30
    # minutes (Session::IMPERSONATION_TTL), always with a case reference.
    class ImpersonationsController < BaseController
      requires_permission "ops.impersonation.start", only: :create
      allow_unauthorized only: :destroy

      def create
        merchant = Merchant.where(livemode: true).find(params.require(:merchant_id))
        current_session.start_impersonation!(merchant_id: merchant.id, case_ref: params.require(:case_reference))
        # One row serves both histories: on the operator side (on_behalf_of) and
        # on the merchant's own security history (merchant_id).
        audit!("impersonation.started", merchant_id: merchant.id, on_behalf_of_merchant_id: merchant.id,
                                         metadata: { "case_reference" => params[:case_reference] })
        render json: { "impersonating" => true, "merchant_id" => merchant.id,
                       "expires_at" => T.must(current_session.impersonation_expires_at).utc.iso8601(3) },
               status: :created
      end

      def destroy
        current_session.stop_impersonation!
        audit!("impersonation.stopped")
        render json: { "impersonating" => false }
      end
    end
  end
end
