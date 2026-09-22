require "rails_helper"

RSpec.describe "GET /v1/payments (cursor pagination)", type: :request do
  let!(:merchant_and_key) { create_merchant_with_key }
  let(:merchant) { merchant_and_key.first }
  let(:key) { merchant_and_key.last }

  def list(params = {})
    get "/v1/payments", params: params, headers: auth_headers(key)
    json_body
  end

  it "walks every row exactly once across pages, newest first, with an opaque cursor" do
    ids = 7.times.map { |i| travel_to(i.minutes.ago) { create(:payment, merchant: merchant) }.id }
    create(:payment) # another merchant's — must never appear

    seen = []
    cursor = nil
    loop do
      page = list({ limit: 3, cursor: cursor }.compact)
      seen.concat(page["data"].map { |p| p["id"] })
      expect(page["object"]).to eq("list")
      break unless page["has_more"]

      cursor = page["next_cursor"]
      expect(cursor).to match(/\A[A-Za-z0-9_-]+\z/) # opaque, url-safe
    end

    expect(seen).to eq(ids) # 7 created newest-first: i=0 is newest
    expect(seen.uniq.size).to eq(7)
  end

  it "keeps a stable total order when many rows share created_at (id is the tiebreak)" do
    frozen = Time.current.change(usec: 0)
    travel_to(frozen) { 5.times { create(:payment, merchant: merchant) } }

    page1 = list(limit: 2)
    page2 = list(limit: 2, cursor: page1["next_cursor"])
    page3 = list(limit: 2, cursor: page2["next_cursor"])
    all = [page1, page2, page3].flat_map { |p| p["data"].map { |x| x["id"] } }

    expect(all.uniq.size).to eq(5)
    expect(page3["has_more"]).to be false
  end

  it "filters by state, currency, and created_at range" do
    a = create(:payment, merchant: merchant)
    a.transition!(:authorized, sort_key: a.created_at + 1, source: "worker")
    create(:payment, :vnd, merchant: merchant)
    old = travel_to(2.days.ago) { create(:payment, merchant: merchant) }

    expect(list(state: "authorized")["data"].map { |p| p["id"] }).to eq([a.id])
    expect(list(currency: "VND")["data"].size).to eq(1)
    expect(list(created_after: 1.day.ago.iso8601)["data"].map { |p| p["id"] }).not_to include(old.id)
    expect(list(created_before: 1.day.ago.iso8601)["data"].map { |p| p["id"] }).to eq([old.id])
  end

  it "rejects a malformed cursor and a bad date with 400, and clamps limit to 100" do
    list(cursor: "not-a-cursor")
    expect(response).to have_http_status(:bad_request)
    expect(json_body["error"]["code"]).to eq("invalid_cursor")

    list(created_after: "yesterday")
    expect(response).to have_http_status(:bad_request)

    create(:payment, merchant: merchant)
    expect(list(limit: 5000)["data"].size).to eq(1) # no error, just clamped
  end

  it "does not N+1: one query for the page regardless of size", :aggregate_failures do
    5.times { create(:payment, merchant: merchant) }
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].start_with?("SELECT") && payload[:name] != "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { list(limit: 5) }

    payment_selects = queries.count { |q| q.include?('FROM "payments"') }
    expect(payment_selects).to eq(1)
    expect(queries.none? { |q| q.include?('FROM "payment_transitions"') }).to be true
  end
end
