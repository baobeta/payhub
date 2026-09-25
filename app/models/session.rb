# typed: true
# frozen_string_literal: true

# One signed-in browser. The cookie holds only the id (signed); everything
# else is here, so revoking a row signs that browser out everywhere.
class Session < ApplicationRecord
  ABSOLUTE_LIFETIME = 12.hours
  STEP_UP_WINDOW = 10.minutes
  ACTIVITY_RESOLUTION = 1.minute

  belongs_to :principal, polymorphic: true

  attribute :last_active_at, :datetime, default: -> { Time.current }

  def active?(idle:)
    revoked_at.nil? && last_active_at > idle.ago && created_at > ABSOLUTE_LIFETIME.ago
  end

  def touch_activity!
    return if last_active_at > ACTIVITY_RESOLUTION.ago

    update_column(:last_active_at, Time.current) # rubocop:disable Rails/SkipsModelValidations
  end

  def stepped_up?
    at = stepped_up_at
    !at.nil? && at > STEP_UP_WINDOW.ago
  end

  def step_up! = update!(stepped_up_at: Time.current)
  def revoke! = update!(revoked_at: Time.current)
end
