# frozen_string_literal: true

require "rails_helper"

RSpec.describe InvitationMailer do
  it "sends a link carrying the token, never the digest" do
    user, token = MerchantUser.invite!(merchant: create(:merchant), email: "new@example.com", role: "support", invited_by: nil)
    described_class.invite(user, token).deliver_now
    body = ActionMailer::Base.deliveries.last.body.to_s
    expect(body).to include("/dashboard/invitations/#{token}")
    expect(body).not_to include(user.invitation_digest)
  end
end
