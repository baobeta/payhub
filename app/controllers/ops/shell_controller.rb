# typed: true
# frozen_string_literal: true

module Ops
  # Serves the empty page the operator Vue app mounts into. The page itself is
  # public; every /ops/api endpoint behind it requires a permission.
  class ShellController < Web::BaseController
    extend T::Sig

    allow_unauthorized only: :show

    sig { void }
    def show = render("web/shell", locals: { entry: "ops", title: "PayHub operations" })

    private

    sig { returns(Symbol) }
    def authorization_area = :operator
  end
end
