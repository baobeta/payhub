# frozen_string_literal: true

# M12 (DECISIONS #25): an admin's authenticator reset emails the member a
# single-use link, as Stripe does
# (https://support.stripe.com/questions/what-do-i-do-if-i-ve-lost-access-to-my-two-step-verification-codes).
# Enrolling a new authenticator then needs that link's token and the
# password. Only the SHA-256 digest is stored, like invitation_digest.
class AddOtpResetTokenToMerchantUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :merchant_users, :otp_reset_digest, :string
    add_column :merchant_users, :otp_reset_expires_at, :datetime
    add_index :merchant_users, :otp_reset_digest, unique: true, where: "otp_reset_digest IS NOT NULL"
  end
end
