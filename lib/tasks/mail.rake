# frozen_string_literal: true

namespace :mail do
  desc "Send a smoke-test email (open http://localhost:1080 to read it)"
  task :smoke, [:to] => :environment do |_t, args|
    SystemMailer.smoke(args[:to] || "dev@payhub.local").deliver_now
    puts "Sent. Open http://localhost:1080"
  end
end
