# frozen_string_literal: true

module DatabaseHelpers
  # Runs the block with row triggers off (superuser-only), so a spec can put a
  # guarded append-only table into a state the application never could, such
  # as a row 13 months old for the retention purge.
  def without_triggers
    connection = ActiveRecord::Base.connection
    connection.execute("SET session_replication_role = replica")
    yield
  ensure
    connection&.execute("SET session_replication_role = DEFAULT")
  end
end

RSpec.configure { |c| c.include DatabaseHelpers }
