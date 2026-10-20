# typed: true

class OutboundDeliveryAttempt < ApplicationRecord
  extend T::Sig

  belongs_to :outbound_event

  validates :attempt_number, numericality: { only_integer: true, greater_than: 0 }
end
