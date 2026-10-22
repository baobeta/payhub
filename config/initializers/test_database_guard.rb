# typed: false
# frozen_string_literal: true

# Fail safe for the test database (lib/test_database.rb): a test-env process,
# or a db:test:* task run from another env, refuses a test database whose name
# does not look like one (payhub_test, payhub_test_<lane>, payhub_e2e) before
# anything is truncated, purged or loaded into it. It catches a
# TEST_DATABASE=payhub_development, or a DATABASE_URL to another database that
# config/application.rb did not drop.
module TestDatabaseGuard
  module DatabaseTasks
    def load_schema(db_config, *)
      TestDatabase.refuse_unless_test!(db_config.database) if db_config.env_name == "test"
      super
    end

    def purge(configuration)
      db_config = resolve_configuration(configuration)
      TestDatabase.refuse_unless_test!(db_config.database) if db_config.env_name == "test"
      super
    end

    private

    def truncate_tables(db_config)
      TestDatabase.refuse_unless_test!(db_config.database) if db_config.env_name == "test"
      super
    end
  end
end

ActiveSupport.on_load(:active_record) do
  if Rails.env.test?
    ActiveRecord::Base.configurations.configs_for(env_name: "test").each do |db_config|
      TestDatabase.refuse_unless_test!(db_config.database)
    end
  end
  ActiveRecord::Tasks::DatabaseTasks.singleton_class.prepend(TestDatabaseGuard::DatabaseTasks)
end
