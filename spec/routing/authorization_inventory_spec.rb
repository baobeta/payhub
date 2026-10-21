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

  # Impersonation is read-only (design §4): the route table, not only the
  # permission shim, must refuse every write.
  it "exposes only GET routes inside the /ops/api/as scope" do
    Rails.application.eager_load!
    writes = Rails.application.routes.routes.filter_map do |route|
      path = route.path.spec.to_s
      next unless path.include?("/ops/api/as/")

      verb = route.verb
      "#{verb} #{path}" unless verb == "GET"
    end
    expect(writes).to be_empty, "Non-GET impersonation routes:\n  #{writes.join("\n  ")}"
  end

  # TC-M9-1: every controller#action is guarded by exactly the permission the
  # fixture says. Fails if a route has been re-wired to a different permission
  # (e.g. capture guarded by payments.read instead of payments.capture) without
  # updating the fixture. Build the fixture from the code with the rails runner
  # snippet in the TC description; it is reviewed by a human, then frozen here.
  it "TC-M9-1: each route is guarded by the permission declared in spec/fixtures/route_permissions.yml" do
    Rails.application.eager_load!
    fixture_path = Rails.root.join("spec/fixtures/route_permissions.yml")
    expected = YAML.load_file(fixture_path)

    mismatches = []
    Rails.application.routes.routes.each do |route|
      controller = route.defaults[:controller]
      action     = route.defaults[:action]
      next unless controller && action

      klass = "#{controller.camelize}Controller".safe_constantize
      next unless klass && klass < Web::BaseController

      key = "#{controller}##{action}"
      # A new route must be added to the fixture deliberately, with its permission.
      next mismatches << "#{key}: missing from route_permissions.yml" unless expected.key?(key)

      # Find the first matching rule (same logic as Authorization#authorize!)
      rules = klass.authorization_rules.select do |rule|
        (rule[:only].nil? || rule[:only].include?(action)) &&
          (rule[:except].nil? || !rule[:except].include?(action))
      end
      actual = if rules.empty?
                 "UNDECLARED"
      elsif rules.first[:kind] == :public
                 "public"
      else
                 rules.first[:permission]
      end

      expected_val = expected[key]
      mismatches << "#{key}: fixture=#{expected_val.inspect} actual=#{actual.inspect}" if actual != expected_val
    end

    expect(mismatches).to be_empty,
      "Routes guarded by the wrong permission:\n  #{mismatches.join("\n  ")}"
  end
end
