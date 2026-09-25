# typed: true
# frozen_string_literal: true

module Dashboard
  # Serves the empty page the merchant Vue app mounts into. The page itself is
  # public; every /dashboard/api endpoint behind it requires a permission.
  class ShellController < Web::BaseController
    allow_unauthorized only: :show

    def show = render("web/shell", locals: { entry: "merchant", title: "PayHub dashboard" })

    private

    def authorization_area = :merchant
  end
end
