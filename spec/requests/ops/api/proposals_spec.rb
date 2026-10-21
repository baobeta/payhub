# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Ops proposals", type: :request do
  let(:maker) { create(:operator, role: "ops") }

  def create_proposal(payment, to_state: "failed", client_token: SecureRandom.uuid)
    post "/ops/api/proposals",
         params: { kind: "payment_transition", payment_id: payment.id, payload: { to_state: },
                   reason_code: "psp_confirmed_outcome", reason_text: "PSP confirmed",
                   case_reference: "OPS-1", client_token: }.to_json, headers: ui_headers
  end

  it "lets ops propose a manual transition, emails approvers and audits it" do
    create(:operator, role: "approver")
    sign_in_operator(maker, stepped_up: true)
    payment = create(:payment, state: "unknown")

    expect do
      create_proposal(payment)
    end.to change(OperatorProposal, :count).by(1)
       .and have_enqueued_mail(OperatorMailer, :proposal_waiting)

    expect(response).to have_http_status(:created)
    expect(json_body.dig("can", "withdraw")).to be(true)
    expect(AuditEvent.where(action: "proposal.created").count).to eq(1)
  end

  it "returns the same proposal for a retried client_token" do
    sign_in_operator(maker, stepped_up: true)
    payment = create(:payment, state: "unknown")
    token = SecureRandom.uuid
    create_proposal(payment, client_token: token)
    first = json_body["id"]

    expect { create_proposal(payment, client_token: token) }.not_to change(OperatorProposal, :count)
    expect(json_body["id"]).to eq(first)
  end

  it "TC-N7-1: refuses another operator's client_token with 409, not a 500" do
    payment = create(:payment, state: "unknown")
    token = SecureRandom.uuid
    sign_in_operator(maker, stepped_up: true)
    create_proposal(payment, client_token: token)

    sign_in_operator(create(:operator, role: "ops"), stepped_up: true)
    expect { create_proposal(payment, client_token: token) }.not_to change(OperatorProposal, :count)

    expect(response).to have_http_status(:conflict)
    expect(json_body.dig("error", "code")).to eq("client_token_in_use")
    expect(response.body).not_to include("PSP confirmed") # nothing of A's proposal leaks
  end

  it "TC-N7-2: two submits of one token at the same moment make one row and both get it back" do
    sign_in_operator(maker, stepped_up: true)
    payment = create(:payment, state: "unknown")
    token = SecureRandom.uuid
    create_proposal(payment, client_token: token)
    expect(response).to have_http_status(:created)
    first = json_body["id"]

    # The second submit looked before the first committed: its lookup saw
    # nothing, so its insert hits the unique index.
    allow(OperatorProposal).to receive(:find_by).and_call_original
    allow(OperatorProposal).to receive(:find_by).with(client_token: token).and_return(nil)
    expect { create_proposal(payment, client_token: token) }.not_to change(OperatorProposal, :count)

    expect(response).to have_http_status(:ok)
    expect(json_body["id"]).to eq(first)
  end

  # No role both proposes and decides, so a self-approval can't reach the
  # service; a double approval hits the same refusal.
  it "TC-N17-1: a refused double approval is audited as a failure with its code" do
    sign_in_operator(maker, stepped_up: true)
    create_proposal(create(:payment, state: "unknown"))
    id = json_body["id"]
    sign_in_operator(create(:operator, role: "approver"), stepped_up: true)
    post "/ops/api/proposals/#{id}/approve", headers: ui_headers

    expect { post "/ops/api/proposals/#{id}/approve", headers: ui_headers }.to change(AuditEvent, :count).by(1)

    expect(response).to have_http_status(:conflict)
    expect(AuditEvent.last).to have_attributes(action: "ops.proposals.decide", result: "failure")
    expect(AuditEvent.last.metadata).to include("code" => "refused", "http_status" => 409)
  end

  it "TC-M14-5: a failing audit write never turns the operator's 409 into a 500" do
    sign_in_operator(maker, stepped_up: true)
    create_proposal(create(:payment, state: "unknown"))
    id = json_body["id"]
    sign_in_operator(create(:operator, role: "approver"), stepped_up: true)
    post "/ops/api/proposals/#{id}/approve", headers: ui_headers
    allow(AuditEvent).to receive(:record!).and_raise(ActiveRecord::ConnectionTimeoutError, "pool exhausted")

    post "/ops/api/proposals/#{id}/approve", headers: ui_headers

    expect(AuditEvent).to have_received(:record!)
    expect(response).to have_http_status(:conflict)
  end

  it "TC-M14-2: an anonymous ops POST writes no audit row" do
    expect { create_proposal(create(:payment, state: "unknown")) }.not_to change(AuditEvent, :count)
    expect(response).to have_http_status(:unauthorized)
  end

  it "forbids support from proposing" do
    sign_in_operator(create(:operator, role: "support"))
    create_proposal(create(:payment, state: "unknown"))
    expect(response).to have_http_status(:forbidden)
  end

  it "lets only the proposer withdraw" do
    sign_in_operator(maker, stepped_up: true)
    create_proposal(create(:payment, state: "unknown"))
    id = json_body["id"]

    sign_in_operator(create(:operator, role: "ops"), stepped_up: true)
    post "/ops/api/proposals/#{id}/withdraw", headers: ui_headers
    expect(response).to have_http_status(409)
    expect(OperatorProposal.find(id).state).to eq("pending")
  end

  it "TC-N6-3: answers 409 to approving or withdrawing an expired proposal" do
    sign_in_operator(maker, stepped_up: true)
    create_proposal(create(:payment, state: "unknown"))
    id = json_body["id"]
    OperatorProposal.where(id:).update_all(state: "expired") # rubocop:disable Rails/SkipsModelValidations

    post "/ops/api/proposals/#{id}/withdraw", headers: ui_headers
    expect(response).to have_http_status(409)

    sign_in_operator(create(:operator, role: "approver"), stepped_up: true)
    post "/ops/api/proposals/#{id}/approve", headers: ui_headers
    expect(response).to have_http_status(409)
    expect(OperatorProposal.find(id).state).to eq("expired")
  end

  # TC-N6-4: withdraw reads the row under DecideProposal's lock. Here an
  # unlocked find returns a stale (pending) copy, as it would for a request
  # that read before an approver or the expiry job committed.
  %w[expired applied].each do |moved_to|
    it "TC-N6-4 a proposal #{moved_to} after the controller loaded it is not overwritten to withdrawn" do
      sign_in_operator(maker, stepped_up: true)
      create_proposal(create(:payment, state: "unknown"))
      id = json_body["id"]
      stale = OperatorProposal.find(id)
      decision = moved_to == "applied" ? { decided_at: Time.current, decided_by_id: create(:operator, role: "approver").id } : {}
      OperatorProposal.where(id:).update_all(state: moved_to, **decision) # rubocop:disable Rails/SkipsModelValidations
      allow(OperatorProposal).to receive(:find).and_call_original
      allow(OperatorProposal).to receive(:find).with(id).and_return(stale)

      post "/ops/api/proposals/#{id}/withdraw", headers: ui_headers

      expect(response).to have_http_status(409)
      expect(OperatorProposal.where(id:).pick(:state)).to eq(moved_to)
      expect(AuditEvent.where(action: "proposal.withdrawn", target_id: id)).to be_empty
    end
  end

  it "applies an approved transition and audits who approved" do
    approver = create(:operator, role: "approver")
    sign_in_operator(maker, stepped_up: true)
    payment = create(:payment, state: "unknown")
    create_proposal(payment)
    id = json_body["id"]

    sign_in_operator(approver, stepped_up: true)
    post "/ops/api/proposals/#{id}/approve", headers: ui_headers

    expect(response).to have_http_status(:ok)
    expect(json_body["state"]).to eq("applied")
    expect(payment.reload.state).to eq("failed")
    expect(AuditEvent.where(action: "proposal.applied").count).to eq(1)
  end

  it "marks the proposal failed when the payment moved before approval" do
    approver = create(:operator, role: "approver")
    sign_in_operator(maker, stepped_up: true)
    payment = create(:payment, state: "unknown")
    create_proposal(payment)
    id = json_body["id"]
    payment.transition!("authorized", sort_key: Time.current, source: "webhook")

    sign_in_operator(approver, stepped_up: true)
    post "/ops/api/proposals/#{id}/approve", headers: ui_headers

    expect(response).to have_http_status(:ok)
    expect(json_body["state"]).to eq("failed")
    expect(payment.reload.state).to eq("authorized")
  end

  it "refuses self-approval even when the operator holds the approving role" do
    sign_in_operator(maker, stepped_up: true)
    create_proposal(create(:payment, state: "unknown"))
    id = json_body["id"]
    maker.update_columns(role: "approver") # rubocop:disable Rails/SkipsModelValidations

    post "/ops/api/proposals/#{id}/approve", headers: ui_headers
    expect(response).to have_http_status(409)
    expect(OperatorProposal.find(id).state).to eq("pending")
  end

  it "requires a note to reject" do
    approver = create(:operator, role: "approver")
    sign_in_operator(maker, stepped_up: true)
    create_proposal(create(:payment, state: "unknown"))
    id = json_body["id"]

    sign_in_operator(approver, stepped_up: true)
    post "/ops/api/proposals/#{id}/reject", headers: ui_headers
    expect(response).to have_http_status(422)
    expect(OperatorProposal.find(id).state).to eq("pending")
  end

  it "forbids ops and admin from deciding" do
    sign_in_operator(maker, stepped_up: true)
    create_proposal(create(:payment, state: "unknown"))
    id = json_body["id"]

    sign_in_operator(maker, stepped_up: true)
    post "/ops/api/proposals/#{id}/approve", headers: ui_headers
    expect(response).to have_http_status(:forbidden)

    sign_in_operator(create(:operator, role: "admin"), stepped_up: true)
    post "/ops/api/proposals/#{id}/approve", headers: ui_headers
    expect(response).to have_http_status(:forbidden)
  end

  it "TC-N8-1: reject sets state to rejected, persists decision_note, and writes an audit row" do # rubocop:disable RSpec/MultipleExpectations
    approver = create(:operator, role: "approver")
    sign_in_operator(maker, stepped_up: true)
    payment = create(:payment, state: "unknown")
    create_proposal(payment)
    id = json_body["id"]

    sign_in_operator(approver, stepped_up: true)
    expect do
      post "/ops/api/proposals/#{id}/reject",
           params: { note: "PSP confirmed the charge never settled" }.to_json,
           headers: ui_headers
    end.to change(AuditEvent, :count).by(1)

    expect(response).to have_http_status(:ok)
    proposal = OperatorProposal.find(id)
    expect(proposal.state).to eq("rejected")
    expect(proposal.decision_note).to eq("PSP confirmed the charge never settled")
    expect(proposal.decided_by).to eq(approver)
    expect(proposal.decided_at).to be_present
    expect(json_body["state"]).to eq("rejected")
    expect(AuditEvent.last).to have_attributes(action: "proposal.rejected", result: "success")
  end

  it "TC-N9-1: approve where apply fails → state failed, error persisted, decided_by and decided_at set" do # rubocop:disable RSpec/MultipleExpectations
    approver = create(:operator, role: "approver")
    sign_in_operator(maker, stepped_up: true)
    payment = create(:payment, state: "unknown")
    create_proposal(payment)
    id = json_body["id"]

    # Move the payment before approval so ApplyProposal raises Stale
    payment.transition!("authorized", sort_key: Time.current, source: "webhook")

    sign_in_operator(approver, stepped_up: true)
    post "/ops/api/proposals/#{id}/approve", headers: ui_headers

    expect(response).to have_http_status(:ok)
    proposal = OperatorProposal.find(id)
    expect(proposal.state).to eq("failed")
    expect(proposal.error).to be_present
    expect(proposal.decided_by).to eq(approver)
    expect(proposal.decided_at).to be_present
    expect(json_body["state"]).to eq("failed")
    # The payment must be unchanged
    expect(payment.reload.state).to eq("authorized")
  end

  describe "TC-N4-1 a ledger correction through the API" do
    let(:payment) { create(:payment, state: "captured") }

    def propose_correction(legs, client_token: SecureRandom.uuid)
      post "/ops/api/proposals",
           params: { kind: "ledger_correction", payment_id: payment.id,
                     payload: { currency: "EUR", legs: },
                     reason_code: "ledger_error", reason_text: "Booked twice by the import",
                     case_reference: "OPS-42", client_token: }.to_json, headers: ui_headers
    end

    def leg(kind, direction, amount) = { account_kind: kind, direction:, amount_minor: amount }

    it "TC-N4-1 creates a proposal with balanced legs (201)" do
      sign_in_operator(maker, stepped_up: true)
      propose_correction([leg("merchant_payable", "debit", 300), leg("psp_receivable", "credit", 300)])

      expect(response).to have_http_status(:created)
      expect(OperatorProposal.find(json_body["id"])).to have_attributes(
        kind: "ledger_correction", state: "pending", case_reference: "OPS-42", reason_code: "ledger_error"
      )
    end

    it "TC-N4-1 refuses unbalanced legs with 422 and creates nothing" do
      sign_in_operator(maker, stepped_up: true)
      expect do
        propose_correction([leg("merchant_payable", "debit", 300), leg("psp_receivable", "credit", 200)])
      end.not_to change(OperatorProposal, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "TC-N4-1 applies the approved correction as one balanced transfer" do
      sign_in_operator(maker, stepped_up: true)
      propose_correction([leg("merchant_payable", "debit", 300), leg("psp_receivable", "credit", 300)])
      id = json_body["id"]

      sign_in_operator(create(:operator, role: "approver"), stepped_up: true)
      post "/ops/api/proposals/#{id}/approve", headers: ui_headers

      expect(json_body["state"]).to eq("applied")
      transfer_id = OperatorProposal.find(id).applied_transfer_id
      entries = LedgerEntry.where(transfer_id:)
      expect(entries.map { |e| [e.direction, e.amount_minor, e.currency, e.payment_id] })
        .to contain_exactly(["debit", 300, "EUR", payment.id], ["credit", 300, "EUR", payment.id])
      expect(Ledger.unbalanced_transfer_ids).to be_empty
    end
  end

  describe "TC-N6-1 withdrawing a pending proposal" do
    it "TC-N6-1 the proposer withdraws it: 200, withdrawn, audited" do
      sign_in_operator(maker, stepped_up: true)
      create_proposal(create(:payment, state: "unknown"))
      id = json_body["id"]

      post "/ops/api/proposals/#{id}/withdraw", headers: ui_headers

      expect(response).to have_http_status(:ok)
      expect(json_body["state"]).to eq("withdrawn")
      expect(OperatorProposal.find(id).state).to eq("withdrawn")
      expect(AuditEvent.where(action: "proposal.withdrawn", target_id: id).sole.actor_id).to eq(maker.id)
    end

    it "TC-N6-1 the proposer can propose again with a new client_token (201)" do
      sign_in_operator(maker, stepped_up: true)
      payment = create(:payment, state: "unknown")
      create_proposal(payment)
      first = json_body["id"]
      post "/ops/api/proposals/#{first}/withdraw", headers: ui_headers

      create_proposal(payment)

      expect(response).to have_http_status(:created)
      expect(json_body["id"]).not_to eq(first)
      expect(OperatorProposal.where(payment:).pluck(:state)).to contain_exactly("withdrawn", "pending")
    end

    it "TC-N6-1 a withdrawn proposal can no longer be approved" do
      sign_in_operator(maker, stepped_up: true)
      payment = create(:payment, state: "unknown")
      create_proposal(payment)
      id = json_body["id"]
      post "/ops/api/proposals/#{id}/withdraw", headers: ui_headers

      sign_in_operator(create(:operator, role: "approver"), stepped_up: true)
      post "/ops/api/proposals/#{id}/approve", headers: ui_headers

      expect(response).to have_http_status(:conflict)
      expect(payment.reload.state).to eq("unknown")
    end
  end
end
