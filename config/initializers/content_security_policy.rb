# frozen_string_literal: true

# Sent on every response. It protects the UI pages; on JSON (/v1) browsers
# ignore it, and a restrictive policy there is what OWASP recommends anyway.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.script_src :self
    policy.style_src :self, :unsafe_inline # Vue transitions and Vite's dev CSS injection
    policy.img_src :self, :data
    policy.connect_src :self
    policy.frame_ancestors :none
    policy.base_uri :self
    policy.form_action :self

    if Rails.env.development?
      # The dev server as Rails sees it (vite:3036 under compose) and as the
      # browser sees it (localhost:3036, where hot reload connects).
      hosts = [ViteRuby.config.host_with_port, "localhost:#{ViteRuby.config.port}"].uniq
      policy.script_src(*policy.script_src, :unsafe_eval, *hosts.map { "http://#{_1}" })
      policy.connect_src(*policy.connect_src, *hosts.flat_map { ["http://#{_1}", "ws://#{_1}"] })
    end
  end
end
