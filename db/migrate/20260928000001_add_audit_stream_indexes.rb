# typed: false
# frozen_string_literal: true

# The operator audit stream orders by (created_at DESC, id DESC) and filters on
# on_behalf_of_merchant_id; neither had an index.
class AddAuditStreamIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :audit_events, %i[created_at id], name: "index_audit_events_on_created_at_and_id",
                                                algorithm: :concurrently
    add_index :audit_events, %i[on_behalf_of_merchant_id created_at],
              name: "index_audit_events_on_behalf_of_merchant_id_and_created_at", algorithm: :concurrently
  end
end
