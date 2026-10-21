class AddMulticaptureToPaymentsAndCaptures < ActiveRecord::Migration[8.1]
  # Several partial captures per payment (DECISIONS #20). A capture is final
  # unless the merchant says otherwise; a final capture, a zero-amount final
  # capture or authorization expiry closes capturing for good.
  def up
    add_column :payments, :captures_closed_at, :datetime
    add_column :captures, :final, :boolean, null: false, default: true
    self.class.backfill!
  end

  def down
    remove_column :captures, :final
    remove_column :payments, :captures_closed_at
  end

  # Before this change every capture was final: a payment that had captured
  # anything could never capture again. Close those, so no old payment
  # suddenly becomes capturable after the deploy.
  def self.backfill!
    execute_sql = <<~SQL
      UPDATE payments SET captures_closed_at = updated_at
      WHERE captures_closed_at IS NULL AND state IN ('captured', 'part_refunded', 'refunded')
    SQL
    ActiveRecord::Base.connection.execute(execute_sql)
  end
end
