# typed: strict
# frozen_string_literal: true

# sorbet-runtime validates every `sig` at call time. That is exactly what we
# want in development and test — a wrong type is a failing test, not a silent
# coercion — but it is per-call overhead in production, where the static check
# (`srb tc` in CI) has already proven the code well-typed.
if Rails.env.production?
  T::Configuration.default_checked_level = :never
else
  # Raise loudly on a sig violation instead of just logging.
  T::Configuration.call_validation_error_handler = lambda do |signature, opts|
    raise TypeError, "#{signature.method_name}: #{opts[:pretty_message]}"
  end
end
