# frozen_string_literal: true

require "rails_helper"

# The real safeguard behind "a new endpoint without a permission fails CI"
# (design §3). The after_action check only fires when an action is exercised;
# this one covers every route whether or not a spec calls it.
RSpec.describe "Authorization inventory" do # rubocop:disable RSpec/DescribeClass
  it "declares requires_permission or allow_unauthorized for every Web action" do
    Rails.application.eager_load!
    undeclared = Rails.application.routes.routes.filter_map do |route|
      controller, action = route.defaults.values_at(:controller, :action)
      next unless controller && action

      klass = "#{controller.camelize}Controller".safe_constantize
      next unless klass && klass < Web::BaseController

      "#{controller}##{action}" unless klass.authorization_declared_for?(action)
    end
    expect(undeclared).to be_empty, "Undeclared UI actions:\n  #{undeclared.join("\n  ")}"
  end

  # Without this, a UI endpoint on ActionController::Base directly would skip
  # the check above, and Authorization with it.
  it "serves every /dashboard, /ops and /demo route from a Web::BaseController" do
    Rails.application.eager_load!
    outside = Rails.application.routes.routes.filter_map do |route|
      path = route.path.spec.to_s
      next unless path.match?(%r{\A/(dashboard|ops|demo)(/|\(|\z)})

      klass = "#{route.defaults[:controller].to_s.camelize}Controller".safe_constantize
      "#{path} → #{route.defaults[:controller]}" unless klass && klass < Web::BaseController
    end
    expect(outside).to be_empty, "UI routes outside Web::BaseController:\n  #{outside.join("\n  ")}"
  end
end
