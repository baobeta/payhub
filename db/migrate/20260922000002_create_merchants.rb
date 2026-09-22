class CreateMerchants < ActiveRecord::Migration[7.2]
  def change
    create_table :merchants, id: :uuid, default: -> { "uuid_generate_v7()" } do |t|
      t.string :name, null: false
      # SHA-256 of the bearer key. The raw key is shown once at creation and never stored.
      t.string :api_key_digest, null: false
      # HMAC secret for the outbound webhooks we send to this merchant.
      t.string :webhook_secret, null: false
      t.string :webhook_url
      t.string :default_currency, limit: 3, null: false

      t.timestamps
    end

    add_index :merchants, :api_key_digest, unique: true
  end
end
