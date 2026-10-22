# typed: strict
# frozen_string_literal: true

# sorbet-runtime validates every `sig` at call time. That is exactly what we
# want in development and test — a wrong type is a failing test, not a silent
# coercion. Production turns the checks off in config/application.rb, which
# has to happen before the first sig loads.
unless Rails.env.production?
  # Raise loudly on a sig violation instead of just logging.
  T::Configuration.call_validation_error_handler = lambda do |signature, opts|
    raise TypeError, "#{signature.method_name}: #{opts[:pretty_message]}"
  end
end
