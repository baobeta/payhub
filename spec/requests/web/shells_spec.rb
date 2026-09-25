# frozen_string_literal: true

require "rails_helper"

RSpec.describe "UI shells", type: :request do
  {
    "/dashboard" => "entrypoints/merchant.ts",
    "/dashboard/payments/abc" => "entrypoints/merchant.ts",
    "/ops" => "entrypoints/ops.ts",
    "/demo" => "entrypoints/demo.ts"
  }.each do |path, entry|
    it "serves #{path} with only its own bundle" do
      get path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(entry.sub("entrypoints/", "").delete_suffix(".ts"))
      others = %w[merchant ops demo] - [entry[%r{entrypoints/(\w+)}, 1]]
      others.each { |other| expect(response.body).not_to include("entrypoints/#{other}") }
    end
  end

  it "puts a CSRF token on the page" do
    # config/environments/test.rb turns forgery protection off, which also
    # blanks csrf_meta_tags; turn it on for the behaviour under test.
    ActionController::Base.allow_forgery_protection = true
    get "/dashboard"
    expect(response.body).to include('name="csrf-token"')
  ensure
    ActionController::Base.allow_forgery_protection = false
  end
end
