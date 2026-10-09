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
end
