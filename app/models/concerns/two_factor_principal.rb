# typed: true
# frozen_string_literal: true

# Password + TOTP login shared by MerchantUser and (phase 2) Operator.
# The columns and associations the including model provides are declared in
# sorbet/rbi/shims/concerns.rbi.
module TwoFactorPrincipal
  extend ActiveSupport::Concern
  extend T::Sig
  extend T::Helpers

  requires_ancestor { ActiveRecord::Base }

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

  module ClassMethods
    extend T::Sig
    extend T::Helpers
    extend T::Generic

    has_attached_class!(:out)

    requires_ancestor { ActiveRecord::Querying }

    sig { params(token: T.nilable(String)).returns(T.nilable(T.attached_class)) }
    def find_by_invitation_token(token)
      return nil if token.blank?

      where(accepted_at: nil, disabled_at: nil).where("invitation_expires_at > ?", Time.current)
                                                .find_by(invitation_digest: Digest::SHA256.hexdigest(token))
    end
  end

  sig { returns(T::Boolean) }
  def active? = disabled_at.nil?
  sig { returns(T::Boolean) }
  def otp_enabled? = otp_enabled_at.present?
  sig { returns(T::Boolean) }
  def locked? = locked_until&.future? || false
  sig { returns(T::Boolean) }
  def pending_invitation? = accepted_at.nil?

  # True once per valid code: the matched time step must be newer than the
  # last one used, so a code read off a shoulder cannot be replayed.
  # The step is claimed with a conditional UPDATE, so two concurrent requests
  # carrying the same code cannot both succeed.
  sig { params(code: T.untyped).returns(T::Boolean) }
  def verify_otp!(code)
    step = Otp.verify(otp_secret, code, after_step: otp_last_used_step)
    return false unless step

    claimed = T.cast(self.class, T.class_of(ActiveRecord::Base)).where(id:).where("otp_last_used_step IS NULL OR otp_last_used_step < ?", step)
                  .update_all(otp_last_used_step: step, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    self.otp_last_used_step = step if claimed == 1
    claimed == 1
  end

  # Returns true when this failure is the one that locked the account. After
  # a lock expires counting starts again, so one typo does not re-lock.
  sig { returns(T::Boolean) }
  def register_failure!
    expired = locked_until&.past?
    attempts = (expired ? 0 : failed_attempts) + 1
    now_locked = attempts >= MAX_FAILURES
    update_columns(failed_attempts: attempts, # rubocop:disable Rails/SkipsModelValidations
                   locked_until: now_locked ? LOCK_FOR.from_now : (expired ? nil : locked_until))
    now_locked
  end

  sig { void }
  def reset_failures!
    update_columns(failed_attempts: 0, locked_until: nil) # rubocop:disable Rails/SkipsModelValidations
  end

  sig { void }
  def revoke_sessions!
    sessions.where(revoked_at: nil).update_all(revoked_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
  end
end
