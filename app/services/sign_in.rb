# typed: true
# frozen_string_literal: true

# First factor. Works for any TwoFactorPrincipal model (MerchantUser now,
# Operator in phase 2). The second factor is checked by the caller.
class SignIn
  Result = Struct.new(:status, :principal, keyword_init: true)

  LOCKED_FALLBACK = TwoFactorPrincipal::LOCK_FOR

  # Compared against when the email is unknown, so both paths cost one bcrypt.
  DUMMY_DIGEST = BCrypt::Password.create("payhub-dummy-password").to_s.freeze

  def self.password(scope, email:, password:)
    principal = scope.active.where.not(accepted_at: nil).find_by("lower(email) = ?", email.to_s.strip.downcase)
    unless principal&.password_digest
      BCrypt::Password.new(DUMMY_DIGEST).is_password?(password.to_s)
      return Result.new(status: :invalid, principal: nil)
    end
    return Result.new(status: :locked, principal:) if principal.locked?

    if principal.authenticate(password.to_s)
      Result.new(status: :ok, principal:)
    else
      principal.register_failure!
      Result.new(status: principal.locked? ? :locked : :invalid, principal: principal.locked? ? principal : nil)
    end
  end
end
