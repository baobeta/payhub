# Add your own tasks in files placed in lib/tasks ending in .rake,
# for example lib/tasks/capistrano.rake, and they will automatically be available to Rake.

# db:schema:dump shells out to `pg_dump`; bin/pg_dump picks a client that
# matches the Postgres 16 server (see that file).
ENV["PATH"] = "#{__dir__}/bin:#{ENV['PATH']}"

require_relative "config/application"

Rails.application.load_tasks
