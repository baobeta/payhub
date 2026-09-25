# typed: true
# frozen_string_literal: true

module Demo
  # Serves the empty page the demo Vue app mounts into. The page itself is
  # public; every /demo/api endpoint behind it requires a permission.
  class ShellController < Web::BaseController
    allow_unauthorized only: :show

    def show = render("web/shell", locals: { entry: "demo", title: "PayHub demo" })

    private

    def authorization_area = :merchant
  end
end
