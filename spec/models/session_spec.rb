# frozen_string_literal: true

require "rails_helper"

RSpec.describe Session do
  let(:user) { create(:merchant_user) }
  let(:session) { described_class.create!(principal: user, ip: "10.0.0.1", user_agent: "rspec") }

  it "expires after the idle timeout" do
    expect(session.active?(idle: 15.minutes)).to be(true)
    travel 16.minutes
    expect(session.active?(idle: 15.minutes)).to be(false)
  end

  it "expires 12 hours after sign-in however active it is" do
    session
    travel 11.hours
    session.touch_activity!
    travel 2.hours
    expect(session.active?(idle: 15.minutes)).to be(false)
  end

  it "records activity at most once a minute" do
    session
    freeze_time do
      travel 2.minutes
      session.touch_activity!
      travel 30.seconds
      session.touch_activity!
      expect(session.reload.last_active_at).to eq(30.seconds.ago)
    end
  end

  it "stays stepped up for 10 minutes" do
    session.update!(stepped_up_at: Time.current)
    travel 9.minutes
    expect(session.stepped_up?).to be(true)
    travel 2.minutes
    expect(session.stepped_up?).to be(false)
  end

  it "is inactive once revoked" do
    session.revoke!
    expect(session.active?(idle: 15.minutes)).to be(false)
  end
end
