class AddFirstSentAtToPayments < ActiveRecord::Migration[7.2]
  def change
    # The first moment any authorize for this payment's reference left us —
    # job or sweeper. `unknown` is dated from it (DECISIONS #11, refined).
    add_column :payments, :first_sent_at, :datetime
  end
end
