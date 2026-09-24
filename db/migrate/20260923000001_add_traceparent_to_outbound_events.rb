class AddTraceparentToOutboundEvents < ActiveRecord::Migration[7.2]
  def change
    # The W3C traceparent the event was emitted in. The delivery sweeper runs
    # in its own trace and links each delivery back to this one.
    add_column :outbound_events, :traceparent, :string
  end
end
