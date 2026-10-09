# frozen_string_literal: true

namespace :operators do
  # bin/rails "operators:invite[you@example.com,admin]"
  # The first operator has to come from a console; everyone else is invited
  # from the Operators screen in /ops (DECISIONS #23, #24).
  desc "Invite a PayHub operator (prints the invitation link; also emailed)"
  task :invite, %i[email role] => :environment do |_t, args|
    operator, token = Operator.invite!(email: args.fetch(:email), role: args.fetch(:role), invited_by: nil)
    OperatorMailer.invite(operator, token).deliver_now
    puts "Invitation for #{operator.email} (#{operator.role}): http://localhost:3000/ops/invitations/#{token}"
  rescue ArgumentError => e
    abort e.message
  end
end
