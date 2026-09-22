class OutboundDeliveryAttempt < ApplicationRecord
  belongs_to :outbound_event

  validates :attempt_number, numericality: { only_integer: true, greater_than: 0 }
end
