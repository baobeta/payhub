# typed: true
# frozen_string_literal: true

# The one merchant the public demo may touch: the TEST twin of the seeded
# "Demo Merchant". Resolved on the server; never taken from a request.
module DemoMerchant
  extend T::Sig

  NAME = "Demo Merchant"

  sig { returns(Merchant) }
  def self.live = Merchant.find_by!(name: NAME, livemode: true)

  sig { returns(Merchant) }
  def self.twin = live.test_twin!

  sig { returns(ActiveSupport::TimeWithZone) }
  def self.epoch_started_at = DemoEpoch.current_started_at

  # Payments the demo shows: the twin's, created since the current epoch.
  sig { returns(ActiveRecord::Relation) }
  def self.payments = twin.payments.where(created_at: epoch_started_at..)
end
