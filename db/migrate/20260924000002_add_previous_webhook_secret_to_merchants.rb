class AddPreviousWebhookSecretToMerchants < ActiveRecord::Migration[7.2]
  def change
    # Webhook secret rotation (DECISIONS #15): the old secret keeps signing
    # alongside the new one until it expires, so a merchant can switch over
    # without dropping a single delivery.
    add_column :merchants, :previous_webhook_secret, :string
    add_column :merchants, :previous_webhook_secret_expires_at, :datetime
  end
end
