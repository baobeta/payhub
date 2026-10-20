# typed: true

class InboundEvent < ApplicationRecord
  extend T::Sig

  validates :psp_name, inclusion: { in: Payment::PSPS }
  validates :external_id, :event_type, :payload, presence: true
  validates :signature_valid, inclusion: { in: [true, false] }

  scope :unprocessed, -> { where(processed_at: nil, signature_valid: true).order(:received_at) }

  sig { returns(T::Boolean) }
  def processed? = processed_at.present?
end
