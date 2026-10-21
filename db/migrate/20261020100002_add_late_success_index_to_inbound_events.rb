# frozen_string_literal: true

# The ops queue lists failed payments the PSP charged anyway (TC-B3-3). Late
# successes are rare and failed payments are every decline, so the list starts
# from these few events instead of probing every failed payment.
class AddLateSuccessIndexToInboundEvents < ActiveRecord::Migration[8.0]
  def change
    add_index :inbound_events, %i[psp_name psp_reference], name: "idx_inbound_events_late_success",
                                                           where: "error LIKE 'late_success_after_failure%'"
  end
end
