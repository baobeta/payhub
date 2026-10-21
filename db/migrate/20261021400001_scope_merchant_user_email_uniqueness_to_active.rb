# frozen_string_literal: true

# M11: a removed member's email can be invited again (GitHub re-invites former
# members). Uniqueness now covers active rows only; the removed row and its
# audit history stay as they were. Operators keep their global unique index.
class ScopeMerchantUserEmailUniquenessToActive < ActiveRecord::Migration[8.0]
  def up
    remove_index :merchant_users, name: "idx_merchant_users_email"
    add_index :merchant_users, "lower((email)::text)", unique: true, where: "disabled_at IS NULL",
                                                        name: "idx_merchant_users_email"
  end

  def down
    remove_index :merchant_users, name: "idx_merchant_users_email"
    add_index :merchant_users, "lower((email)::text)", unique: true, name: "idx_merchant_users_email"
  end
end
