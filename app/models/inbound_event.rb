# typed: true

class InboundEvent < ApplicationRecord
  validates :psp_name, inclusion: { in: Payment::PSPS }
  validates :external_id, :event_type, :payload, presence: true
  validates :signature_valid, inclusion: { in: [true, false] }

  scope :unprocessed, -> { where(processed_at: nil, signature_valid: true).order(:received_at) }

  def processed? = processed_at.present?
end
