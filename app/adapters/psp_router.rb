# typed: strict
# frozen_string_literal: true

# The routing rule: which PSP handles a currency. Adapters declare the
# currencies they speak; the router is derived from those declarations, so
# adding a PSP is one line here and zero `if psp ==` anywhere else.
module PspRouter
  extend T::Sig

  class NoRoute < StandardError; end

  ADAPTERS = T.let(
    { "nordpay" => NordpayAdapter }.freeze,
    T::Hash[String, T.class_of(PspAdapter)]
  )

  class << self
    extend T::Sig

    sig { params(currency: String).returns(String) }
    def name_for(currency)
      ADAPTERS.each { |name, klass| return name if klass.new.currencies.include?(currency) }
      raise NoRoute, "no PSP routes #{currency}"
    end

    sig { params(name: String).returns(PspAdapter) }
    def adapter(name)
      ADAPTERS.fetch(name) { raise NoRoute, "unknown PSP #{name.inspect}" }.new
    end

    sig { params(currency: String).returns(PspAdapter) }
    def for_currency(currency) = adapter(name_for(currency))
  end
end
