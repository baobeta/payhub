# typed: true
# frozen_string_literal: true

# One row of "your sessions" (M7). Browser and OS are a coarse label from the
# user agent, enough to recognise a device, as GitHub's session list does. No
# geo-IP (out of scope, docs/TEST_CASES.md §5).
module SessionSerializer
  extend T::Sig

  # First match wins, so the more specific tokens come first (Edge and Opera
  # also say Chrome; Chrome also says Safari).
  BROWSERS = T.let([[/Edg(e|A|iOS)?\//, "Edge"], [/OPR\/|Opera/, "Opera"], [/Firefox\/|FxiOS/, "Firefox"],
                    [/Chrome\/|CriOS/, "Chrome"], [/Safari\//, "Safari"]].freeze, T::Array[[Regexp, String]])
  SYSTEMS = T.let([[/iPhone|iPad|iPod/, "iOS"], [/Android/, "Android"], [/CrOS/, "ChromeOS"],
                   [/Windows/, "Windows"], [/Macintosh|Mac OS X/, "macOS"], [/Linux|X11/, "Linux"]].freeze,
                  T::Array[[Regexp, String]])

  sig { params(row: Session, current: Session).returns(T::Hash[String, T.untyped]) }
  def self.call(row, current:)
    ua = row.user_agent.to_s
    {
      "id" => row.id, "browser" => label(BROWSERS, ua), "os" => label(SYSTEMS, ua), "ip" => row.ip,
      "created_at" => row.created_at.utc.iso8601, "last_active_at" => row.last_active_at.utc.iso8601,
      "current" => row.id == current.id
    }
  end

  sig { params(table: T::Array[[Regexp, String]], user_agent: String).returns(String) }
  def self.label(table, user_agent) = table.find { |pattern, _| pattern.match?(user_agent) }&.last || "Unknown"
end
