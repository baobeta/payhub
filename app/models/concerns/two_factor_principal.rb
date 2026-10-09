# typed: false
# frozen_string_literal: true

# Password + TOTP login shared by MerchantUser and (phase 2) Operator.
# typed: false: has_secure_password and encrypts are class macros Sorbet
# cannot see from inside a concern; the model specs cover this module.
module TwoFactorPrincipal
  extend ActiveSupport::Concern

  MAX_FAILURES = 10
  LOCK_FOR = 30.minutes
  MIN_PASSWORD_LENGTH = 12

  included do
    has_secure_password validations: false
    encrypts :otp_secret

    has_many :sessions, as: :principal, dependent: :restrict_with_exception
    has_many :recovery_codes, as: :principal, dependent: :restrict_with_exception

    validates :password, length: { minimum: MIN_PASSWORD_LENGTH }, allow_nil: true
    validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }
    before_validation { self.email = email.to_s.strip.downcase }

    scope :active, -> { where(disabled_at: nil) }
  end

  class_methods do
    def find_by_invitation_token(token)
      return nil if token.blank?

      where(accepted_at: nil, disabled_at: nil).where("invitation_expires_at > ?", Time.current)
                                                .find_by(invitation_digest: Digest::SHA256.hexdigest(token))
    end
  end

  def active? = disabled_at.nil?
  def otp_enabled? = otp_enabled_at.present?
  def locked? = locked_until.present? && locked_until.future?
  def pending_invitation? = accepted_at.nil?

  # True once per valid code: the matched time step must be newer than the
  # last one used, so a code read off a shoulder cannot be replayed.
  # The step is claimed with a conditional UPDATE, so two concurrent requests
  # carrying the same code cannot both succeed.
  def verify_otp!(code)
    step = Otp.verify(otp_secret, code, after_step: otp_last_used_step)
    return false unless step

    claimed = self.class.where(id:).where("otp_last_used_step IS NULL OR otp_last_used_step < ?", step)
                  .update_all(otp_last_used_step: step, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    self.otp_last_used_step = step if claimed == 1
    claimed == 1
  end

  # Returns true when this failure is the one that locked the account. After
  # a lock expires counting starts again, so one typo does not re-lock.
  def register_failure!
    expired = locked_until&.past?
    attempts = (expired ? 0 : failed_attempts) + 1
    now_locked = attempts >= MAX_FAILURES
    update_columns(failed_attempts: attempts, # rubocop:disable Rails/SkipsModelValidations
                   locked_until: now_locked ? LOCK_FOR.from_now : (expired ? nil : locked_until))
    now_locked
  end

  def reset_failures!
    update_columns(failed_attempts: 0, locked_until: nil) # rubocop:disable Rails/SkipsModelValidations
  end

  def revoke_sessions!
    sessions.where(revoked_at: nil).update_all(revoked_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
  end
end
