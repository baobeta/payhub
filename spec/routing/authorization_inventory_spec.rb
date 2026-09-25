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
end
