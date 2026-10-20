class AddAttemptBudgetToOutboundEvents < ActiveRecord::Migration[8.1]
  # A redelivered dead event gets a fresh retry budget on top of the attempts
  # it already used, so attempt numbers keep climbing (they are unique per
  # event) while the merchant still gets MAX_ATTEMPTS more tries (Stripe: a
  # manual resend is a fresh delivery with its own retries).
  def up
    add_column :outbound_events, :attempt_budget, :integer, null: false, default: 8
    # An event already redelivered under the old rule is still pending past
    # its first budget: give it the full new one, not a single try.
    execute "UPDATE outbound_events SET attempt_budget = attempts + 8 WHERE state = 'pending' AND attempts >= 8"
  end

  def down
    remove_column :outbound_events, :attempt_budget
  end
end
