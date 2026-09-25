# frozen_string_literal: true

require "rails_helper"

RSpec.describe SystemMailer do
  it "delivers a smoke-test email through the configured delivery method" do
    expect { described_class.smoke("ops@example.com").deliver_now }
      .to change(ActionMailer::Base.deliveries, :size).by(1)
    expect(ActionMailer::Base.deliveries.last.to).to eq(["ops@example.com"])
  end
end
