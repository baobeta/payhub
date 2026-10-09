# typed: true
# frozen_string_literal: true

module Ops
  module Api
    # O-02 search, O-03 superset detail, O-04 poll now.
    class PaymentsController < BaseController
      requires_permission "ops.payments.read", only: %i[index show]
      requires_permission "ops.payments.poll", only: :poll

      def index
        rows = search(params[:q].to_s.strip).includes(:merchant).order(created_at: :desc).limit(50)
        render json: {
          "data" => rows.map do |p|
            PaymentSerializer.call(p).merge("merchant" => T.must(p.merchant).name,
                                            "livemode" => T.must(p.merchant).livemode)
          end
        }
      end

      def show = render(json: OpsPaymentDetail.call(Payment.find(params[:id])))

      def poll
        payment = Payment.find(params[:id])
        StuckPaymentSweeperJob.poll_now(payment)
        audit!("payment.polled", target: payment, merchant_id: payment.merchant_id)
        render json: OpsPaymentDetail.call(payment.reload)
      end

      private

      # An exact id or psp_reference; otherwise a merchant-name prefix. Never a
      # %term% scan over payments (design §8).
      def search(q)
        if q.match?(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
          Payment.where(id: q)
        elsif q.start_with?("ph_")
          Payment.where(psp_reference: q)
        elsif q.length >= 2
          Payment.where(merchant_id: Merchant.where("name ILIKE ?", "#{Merchant.sanitize_sql_like(q)}%").select(:id))
        else
          Payment.none
        end
      end
    end
  end
end
