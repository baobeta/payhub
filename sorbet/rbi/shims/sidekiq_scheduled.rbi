# typed: true

# sidekiq-cron's RBI refers to Sidekiq::Scheduled::Poller, which sidekiq
# only defines when sidekiq/scheduled is required at server boot, so tapioca
# did not see it when compiling the sidekiq gem RBI.
module Sidekiq::Scheduled
  class Poller; end
end
