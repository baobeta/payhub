# frozen_string_literal: true

require "rails_helper"

RSpec.describe CancelPayment do
  let(:payment) { create(:payment, state: "authorized") }

  it "keeps the psp_calls row written during the call when the transition loses" do
    adapter = instance_double(NordpayAdapter)
    allow(PspRouter).to receive(:adapter).with(payment.psp_name).and_return(adapter)
    allow(adapter).to receive(:cancel) do
      PspCallLog.record(psp: payment.psp_name, method: :post, path: "/charges/#{payment.psp_reference}/void",
                        headers: {}, request_body: nil, status: 200, response_body: { "status" => "canceled" },
                        outcome: "ok", started_at: Time.current, params: {})
      # A capture lands on the wire while we were on the PSP.
      Payment.where(id: payment.id).update_all(state: "captured") # rubocop:disable Rails/SkipsModelValidations
      PspAdapter::Result.new(status: PspAdapter::Result::Status::Canceled, psp_reference: payment.psp_reference,
                             psp_charge_id: "ch_1", decline_code: nil, psp_timestamp: Time.current)
    end

    expect { described_class.call(payment) }.to raise_error(ApiError, /only authorized/)
    expect(PspCall.where(psp_reference: payment.psp_reference).count).to eq(1)
  end

  # Real threads, real connections: the row lock must serialise the two money
  # moves so exactly one applies.
  it "lets exactly one of a cancel and a capture apply", :concurrency do
    payment = create(:payment, state: "authorized")
    adapter = Class.new do
      def cancel(payment)
        sleep 0.02
        PspAdapter::Result.new(status: PspAdapter::Result::Status::Canceled, psp_reference: payment.psp_reference,
                               psp_charge_id: "ch_1", decline_code: nil, psp_timestamp: Time.current)
      end
    end
    allow(PspRouter).to receive(:adapter).and_return(adapter.new)
    barrier = Concurrent::CyclicBarrier.new(2)
    results = Concurrent::Array.new

    cancel = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        barrier.wait
        described_class.call(Payment.find(payment.id))
        results << :canceled
      rescue ApiError
        results << :rejected
      end
    end
    capture = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        barrier.wait
        p = Payment.find(payment.id)
        p.with_lock { p.transition!(:captured, sort_key: Time.current, source: "worker") }
        results << :captured
      rescue PaymentStateMachine::IllegalTransition, ApiError
        results << :rejected
      end
    end
    [cancel, capture].each(&:join)

    expect(results.count { |r| %i[canceled captured].include?(r) }).to eq(1)
    expect(Payment.find(payment.id).state).to eq(results.include?(:canceled) ? "canceled" : "captured")
  end
end
