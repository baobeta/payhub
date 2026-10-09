# frozen_string_literal: true

require "rails_helper"

RSpec.describe SecurityMailer do
  it "tells the user where a new sign-in came from" do
    user = create(:merchant_user)
    described_class.new_sign_in(user, ip: "1.2.3.4", user_agent: "Firefox").deliver_now
    mail = ActionMailer::Base.deliveries.last
    expect(mail.to).to eq([user.email])
    expect(mail.body.to_s).to include("1.2.3.4", "Firefox")
  end
end
