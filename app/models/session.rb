# typed: true
# frozen_string_literal: true

# One signed-in browser. The cookie holds only the id (signed); everything
# else is here, so revoking a row signs that browser out everywhere.
class Session < ApplicationRecord
  extend T::Sig

  ABSOLUTE_LIFETIME = 12.hours
  STEP_UP_WINDOW = 10.minutes
  ACTIVITY_RESOLUTION = 1.minute
  IMPERSONATION_TTL = 30.minutes

  belongs_to :principal, polymorphic: true

  attribute :last_active_at, :datetime, default: -> { Time.current }

  # The SQL twin of active?: rows that would still let their browser in.
  scope :live, lambda { |idle:|
    where(revoked_at: nil).where("last_active_at > ?", idle.ago).where("created_at > ?", ABSOLUTE_LIFETIME.ago)
  }

  sig { params(idle: T.untyped).returns(T::Boolean) }
  def active?(idle:)
    revoked_at.nil? && last_active_at > idle.ago && created_at > ABSOLUTE_LIFETIME.ago
  end

  sig { void }
  def touch_activity!
    return if last_active_at > ACTIVITY_RESOLUTION.ago

    update_column(:last_active_at, Time.current) # rubocop:disable Rails/SkipsModelValidations
  end

  sig { returns(T::Boolean) }
  def stepped_up?
    at = stepped_up_at
    !at.nil? && at > STEP_UP_WINDOW.ago
  end

  sig { returns(T::Boolean) }
  def step_up! = update!(stepped_up_at: Time.current)

  sig { returns(T::Boolean) }
  def revoke! = update!(revoked_at: Time.current)

  sig { returns(T::Boolean) }
  def impersonating? = impersonating_merchant_id.present? && impersonation_expires_at&.future?

  sig { params(merchant_id: String, case_ref: String).returns(T::Boolean) }
  def start_impersonation!(merchant_id:, case_ref:)
    update!(impersonating_merchant_id: merchant_id, impersonation_case_ref: case_ref,
            impersonation_expires_at: IMPERSONATION_TTL.from_now)
  end

  sig { returns(T::Boolean) }
  def stop_impersonation!
    update!(impersonating_merchant_id: nil, impersonation_case_ref: nil, impersonation_expires_at: nil)
  end
end
