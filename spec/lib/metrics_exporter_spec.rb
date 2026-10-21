require "rails_helper"
require "rack/mock"
require "net/http"

RSpec.describe MetricsExporter do
  def get(app, path = "/metrics", headers = {})
    Rack::MockRequest.new(app).get(path, headers)
  end

  it "PR-5: serves the registry in Prometheus text format, guarded by the same token" do
    Metrics.increment(:late_success, psp: "kiripay")
    app = described_class.rack_app(token: "s3cret")

    denied = get(app)
    expect(denied.status).to eq(401)
    expect(denied.headers["WWW-Authenticate"]).to eq('Bearer realm="metrics"')

    ok = get(app, "/metrics", "HTTP_AUTHORIZATION" => "Bearer s3cret")
    expect(ok.status).to eq(200)
    expect(ok.body).to include('payhub_late_success_total{psp="kiripay"}')
  end

  it "PR-5: an unknown path is 404 even with a valid token" do
    app = described_class.rack_app(token: "s3cret")

    expect(get(app, "/other", "HTTP_AUTHORIZATION" => "Bearer s3cret").status).to eq(404)
  end

  it "PR-5: outside production an unset token leaves it open" do
    expect(get(described_class.rack_app(token: nil)).status).to eq(200)
  end

  it "PR-5: in production an unset token refuses every scrape" do
    allow(Rails.env).to receive(:production?).and_return(true)

    expect(get(described_class.rack_app(token: nil)).status).to eq(401)
  end

  it "PR-5: start! binds the port and answers over HTTP" do
    Metrics.increment(:late_success, psp: "nordpay")
    webmock = WebMock::Config.instance
    saved = [webmock.allow_localhost, webmock.allow]
    webmock.allow_localhost = true # a real socket this time
    port = TCPServer.open("127.0.0.1", 0) { |s| s.addr[1] }
    server = described_class.start!(host: "127.0.0.1", port: port, token: "s3cret")

    request = Net::HTTP::Get.new("/metrics", "Authorization" => "Bearer s3cret")
    response = Net::HTTP.start("127.0.0.1", port) { |http| http.request(request) }
    expect(response.code).to eq("200")
    expect(response.body).to include('payhub_late_success_total{psp="nordpay"}')
  ensure
    server&.stop(true)
    webmock.allow_localhost, webmock.allow = saved if saved
  end

  it "PR-5: start! logs and returns nil when the port is taken, instead of raising" do
    blocker = TCPServer.new("127.0.0.1", 0)
    allow(Rails.logger).to receive(:error)

    expect(described_class.start!(host: "127.0.0.1", port: blocker.addr[1])).to be_nil
    expect(Rails.logger).to have_received(:error).with(/Worker metrics disabled \(127\.0\.0\.1:\d+\): Errno::EADDRINUSE/)
  ensure
    blocker&.close
  end

  it "PR-5: start! logs and returns nil for a port that is not a number" do
    allow(Rails.logger).to receive(:error)

    expect(described_class.start!(host: "127.0.0.1", port: "abc")).to be_nil
    expect(Rails.logger).to have_received(:error).with(/Worker metrics disabled \(127\.0\.0\.1:abc\): ArgumentError/)
  end

  it "PR-5: start! logs and returns nil for a host that does not resolve" do
    allow(Rails.logger).to receive(:error)

    expect(described_class.start!(host: "no-such-host.invalid", port: "0")).to be_nil
    expect(Rails.logger).to have_received(:error).with(/Worker metrics disabled \(no-such-host\.invalid:0\)/)
  end
end
