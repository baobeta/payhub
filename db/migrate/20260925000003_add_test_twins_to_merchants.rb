class AddTestTwinsToMerchants < ActiveRecord::Migration[8.1]
  # Test mode is a second merchant row (design §2). Every query is already
  # scoped by merchant_id, so test and live data are separated by scoping that
  # exists, with no livemode column on payments, refunds or the ledger.
  def up
    add_column :merchants, :livemode, :boolean, null: false, default: true
    add_reference :merchants, :live_merchant, type: :uuid, foreign_key: { to_table: :merchants },
                                              index: { unique: true, name: "idx_merchants_one_test_twin" }
    add_check_constraint :merchants, "livemode = (live_merchant_id IS NULL)", name: "chk_merchants_twin_shape"
  end

  def down
    remove_check_constraint :merchants, name: "chk_merchants_twin_shape"
    remove_reference :merchants, :live_merchant
    remove_column :merchants, :livemode
  end
end
