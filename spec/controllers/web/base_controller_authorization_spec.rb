# frozen_string_literal: true

require "rails_helper"

RSpec.describe Web::BaseController, type: :controller do
  controller(described_class) do
    requires_permission "payments.refund", only: :create
    requires_permission "payments.read", only: :index
    allow_unauthorized only: :show

    attr_accessor :test_role

    def index = render(json: { ok: true })
    def create = render(json: { ok: true })
    def show = render(json: { ok: true })
    def destroy = render(json: { ok: true }) # declared nowhere

    private

    def authorization_area = :merchant
    def authorization_role = request.headers["X-Test-Role"]
    def step_up_fresh? = request.headers["X-Test-Stepped-Up"] == "1"
  end

  # An anonymous subclass of a namespaced controller keeps its parent's path.
  before { routes.draw { resources :anonymous, controller: "web/base" } }

  it "allows a role that holds the permission" do
    request.headers["X-Test-Role"] = "support"
    request.headers["X-Test-Stepped-Up"] = "1"
    post :create
    expect(response).to have_http_status(:ok)
  end

  it "denies with 403 and the standard error shape" do
    request.headers["X-Test-Role"] = "viewer"
    post :create
    expect(response).to have_http_status(:forbidden)
    expect(JSON.parse(response.body).dig("error", "code")).to eq("forbidden")
  end

  it "audits the denial with the permission and route, never the body" do
    request.headers["X-Test-Role"] = "viewer"
    expect { post :create, params: { secret: "x" } }.to change(AuditEvent, :count).by(1)
    event = AuditEvent.last
    expect(event).to have_attributes(action: "authorization.denied", result: "denied")
    expect(event.metadata).to include("permission" => "payments.refund", "role" => "viewer")
    expect(event.metadata.to_json).not_to include("secret")
  end

  it "runs an explicitly public action without a role" do
    get :show, params: { id: 1 }
    expect(response).to have_http_status(:ok)
  end

  it "raises in test when an action declares nothing" do
    request.headers["X-Test-Role"] = "owner"
    expect { delete :destroy, params: { id: 1 } }.to raise_error(Authorization::NotDeclared, /destroy/)
  end

  it "rejects an unknown permission at declaration time" do
    expect { Class.new(described_class) { requires_permission "payments.refnud" } }
      .to raise_error(Permissions::Unknown)
  end

  it "reports which actions are declared, for the route inventory" do
    expect(controller.class.authorization_declared_for?("create")).to be(true)
    expect(controller.class.authorization_declared_for?("show")).to be(true)
    expect(controller.class.authorization_declared_for?("destroy")).to be(false)
  end

  it "answers 401 without an audit row when nobody is signed in" do
    expect { post :create }.not_to change(AuditEvent, :count)
    expect(response).to have_http_status(:unauthorized)
  end

  it "asks for step-up before a sensitive permission" do
    request.headers["X-Test-Role"] = "support"
    post :create
    expect(response).to have_http_status(:unauthorized)
    expect(JSON.parse(response.body).dig("error", "code")).to eq("step_up_required")
  end

  it "does not ask for step-up on a non-sensitive permission" do
    request.headers["X-Test-Role"] = "viewer"
    get :index
    expect(response).to have_http_status(:ok)
  end

  it "denies and audits an unknown role instead of failing with 500" do
    request.headers["X-Test-Role"] = "superuser"
    expect { get :index }.to change(AuditEvent, :count).by(1)
    expect(response).to have_http_status(:forbidden)
  end
end
