# This configuration file will be evaluated by Puma. The top-level methods that
# are invoked here are part of Puma's configuration DSL. For more information
# about methods provided by the DSL, see https://puma.io/puma/Puma/DSL.html.

# Puma starts a configurable number of processes (workers) and each process
# serves each request in a thread from an internal thread pool.
#
# The ideal number of threads per worker depends both on how much time the
# application spends waiting for IO operations and on how much you wish to
# to prioritize throughput over latency.
#
# As a rule of thumb, increasing the number of threads will increase how much
# traffic a given process can handle (throughput), but due to CRuby's
# Global VM Lock (GVL) it has diminishing returns and will degrade the
# response time (latency) of the application.
#
# The default is set to 3 threads as it's deemed a decent compromise between
# throughput and latency for the average Rails application.
#
# Any libraries that use a connection pool or another resource pool should
# be configured to provide at least as many connections as the number of
# threads. This includes Active Record's `pool` parameter in `database.yml`.
threads_count = ENV.fetch("RAILS_MAX_THREADS", 3)
threads threads_count, threads_count

# Specifies the `port` that Puma will listen on to receive requests; default is 3000.
port ENV.fetch("PORT", 3000)

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart

# Specify the PID file. Defaults to tmp/pids/server.pid in development.
# In other environments, only set the PID file if requested.
pidfile ENV["PIDFILE"] if ENV["PIDFILE"]

# Workers: Puma reads WEB_CONCURRENCY itself (unset or 0: single mode; 1 or
# more: cluster mode with that many worker processes; "auto": one per CPU) and
# preloads the app from 2 workers, so neither is set here. A value that is not
# a number fails the boot.
# No fork hooks: Rails reconnects Active Record after the fork, Redis clients
# reconnect on their own, and the metrics file store opens one file per PID
# (RUNBOOK "Metrics across processes").
# Database connections: each Puma worker uses up to its thread count (above,
# default 3), each Sidekiq process up to its concurrency (config/sidekiq.yml,
# 5). The pool (database.yml) also reads RAILS_MAX_THREADS but defaults to 5,
# so the worker, which leaves it unset, gets a pool that covers its
# concurrency. Size Postgres or PgBouncer for web containers x WEB_CONCURRENCY
# x threads + worker containers x Sidekiq concurrency (README "Configuration").

# On SIGTERM (docker stop) Puma drains first, then by default re-raises the
# signal so the process dies of it. As PID 1 in a container the kernel ignores
# that, and Ruby exits 1, which looks like a crash. Exit 0 after the drain.
raise_exception_on_sigterm false
