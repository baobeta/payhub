# frozen_string_literal: true

require "rails_helper"

# The append-only triggers protect the data only if the role the app connects
# as cannot drop or disable them (db/roles.sql, RUNBOOK "Database roles").
#
# Transactional on purpose: db/roles.sql, the roles it creates (they are
# cluster-wide) and the ownership it hands to payhub_owner all roll back with
# the example. A failing statement aborts the transaction, so each one that
# must be refused runs in its own savepoint and the next starts clean.
RSpec.describe "database roles" do # rubocop:disable RSpec/DescribeClass
  let(:conn) { ActiveRecord::Base.connection }

  # Every user trigger in schema public: the append-only guards and the rest.
  # A trigger added later is covered without touching this spec.
  let(:triggers) do
    conn.select_rows(<<~SQL)
      SELECT t.tgname, c.relname FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
      WHERE c.relnamespace = 'public'::regnamespace AND NOT t.tgisinternal ORDER BY 2, 1
    SQL
  end

  let(:roles_sql) { Rails.root.join("db/roles.sql").read }
  let(:db) { conn.quote_table_name(conn.current_database) }

  before { conn.execute(roles_sql) }

  def as_role(role)
    conn.execute("SET ROLE #{role}")
    yield
  ensure
    conn.execute("RESET ROLE") # the example's rollback would also undo it
  end

  def expect_refused(sql, message)
    expect { conn.transaction(requires_new: true) { conn.execute(sql) } }
      .to raise_error(ActiveRecord::StatementInvalid, message)
  end

  def owners
    conn.select_values(<<~SQL)
      SELECT DISTINCT relowner::regrole::text FROM pg_class
      WHERE relnamespace = 'public'::regnamespace AND relkind IN ('r', 'p', 'v', 'm', 'S')
      UNION
      SELECT DISTINCT p.proowner::regrole::text FROM pg_proc p
      WHERE p.pronamespace = 'public'::regnamespace
        AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
      UNION
      SELECT DISTINCT t.typowner::regrole::text FROM pg_type t
      WHERE t.typnamespace = 'public'::regnamespace AND t.typtype IN ('e', 'd', 'c', 'r') AND t.typrelid = 0
    SQL
  end

  def memberships = conn.select_values("SELECT roleid::regrole::text FROM pg_auth_members WHERE member = 'payhub_app'::regrole")

  def privileges
    conn.select_rows(<<~SQL)
      SELECT relname, relowner::regrole::text, relacl::text FROM pg_class
      WHERE relnamespace = 'public'::regnamespace AND relkind IN ('r', 'p', 'S') ORDER BY 1
    SQL
  end

  # Rows written as the superuser in replica mode, so stamp_created_at keeps
  # the created_at given.
  def backdated_audit_event(created_at)
    conn.execute("SET session_replication_role = replica")
    conn.execute("INSERT INTO audit_events (id, action, result, created_at) " \
                 "VALUES (gen_random_uuid(), 'roles.spec', 'success', #{conn.quote(created_at.utc)}) ")
    conn.execute("SET session_replication_role = DEFAULT")
  end

  it "PR-13: makes payhub_owner the owner of every table, routine and type, and the app role a plain login" do
    conn.execute("CREATE TYPE roles_spec_mood AS ENUM ('ok')") # as the superuser, then handed over by the rerun
    conn.execute(roles_sql)
    expect(owners).to eq(["payhub_owner"])
    expect(conn.select_rows("SELECT rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls, rolcanlogin " \
                            "FROM pg_roles WHERE rolname = 'payhub_app'")).to eq([[false, false, false, false, false, true]])
    expect(memberships).to be_empty
  end

  it "PR-13: is idempotent" do
    before_rerun = [owners, privileges, memberships]
    conn.execute(roles_sql)
    expect([owners, privileges, memberships]).to eq(before_rerun)
  end

  it "PR-13: takes back what was granted to the app role by hand" do
    conn.execute("GRANT TRUNCATE, TRIGGER ON ledger_entries TO payhub_app")
    conn.execute("GRANT payhub_owner TO payhub_app")
    conn.execute("GRANT TEMPORARY ON DATABASE #{db} TO payhub_app")
    conn.execute(roles_sql)
    expect(memberships).to be_empty
    expect(conn.select_rows(<<~SQL)).to eq([[false, false, true, false]])
      SELECT has_table_privilege('payhub_app', 'ledger_entries', 'TRUNCATE'),
             has_table_privilege('payhub_app', 'ledger_entries', 'TRIGGER'),
             has_table_privilege('payhub_app', 'ledger_entries', 'INSERT'),
             has_database_privilege('payhub_app', current_database(), 'TEMPORARY')
    SQL
  end

  it "PR-13: lets the app role write the rows the app writes, and read the schema version at boot" do
    as_role("payhub_app") do
      merchant = create(:merchant)
      payment = create(:payment, merchant:)
      Ledger.record!(merchant:, currency: "EUR", payment:, legs: [
                       Ledger::Leg.new(account_kind: "psp_receivable", direction: "debit", amount_minor: 2500),
                       Ledger::Leg.new(account_kind: "merchant_payable", direction: "credit", amount_minor: 2500)
                     ])
      AuditEvent.record!(action: "roles.spec", result: "success", merchant_id: merchant.id)
      payment.update!(payment_method_token: "tok_mastercard")

      fx = FxRate.create!(base: "USD", quote: "EUR", rate: "0.92", captured_at: Time.current)
      expect(FxRate.where(id: fx.id).delete_all).to eq(1)
      expect(LedgerEntry.where(payment:).count).to eq(2)
      expect(ActiveRecord::Base.connection_pool.migration_context.needs_migration?).to be(false)
      expect(ActiveRecord::InternalMetadata.new(ActiveRecord::Base.connection_pool)[:environment]).to eq("test")
      # Read-only to it: only db: tasks write them, as payhub_owner.
      expect_refused("INSERT INTO schema_migrations (version) VALUES ('1')", /permission denied for table schema_migrations/)
      expect_refused("UPDATE ar_internal_metadata SET value = 'production'", /permission denied for table ar_internal_metadata/)
      expect_refused("DELETE FROM schema_migrations", /permission denied for table schema_migrations/)
    end
  end

  it "PR-13: lets the app role run the retention purge, which deletes only rows older than 12 months" do
    backdated_audit_event(13.months.ago)
    AuditEvent.record!(action: "roles.spec", result: "success")
    as_role("payhub_app") { AuditRetentionJob.perform_now }
    expect(AuditEvent.where(action: "roles.spec").pluck(:created_at)).to contain_exactly(be_within(1.minute).of(Time.current))
  end

  it "PR-13: leaves the append-only tables to their triggers: the app role inserts, never updates or deletes" do
    as_role("payhub_app") do
      merchant = create(:merchant)
      Ledger.record!(merchant:, currency: "EUR", legs: [
                       Ledger::Leg.new(account_kind: "psp_receivable", direction: "debit", amount_minor: 100),
                       Ledger::Leg.new(account_kind: "merchant_payable", direction: "credit", amount_minor: 100)
                     ])
      AuditEvent.record!(action: "roles.spec", result: "success", merchant_id: merchant.id)

      expect_refused("UPDATE ledger_entries SET amount_minor = amount_minor + 1", /ledger_entries is append-only/)
      expect_refused("DELETE FROM ledger_entries", /ledger_entries is append-only/)
      expect_refused("UPDATE audit_events SET result = 'failure'", /audit_events is append-only/)
      expect_refused("DELETE FROM audit_events", /audit_events is append-only/)
      expect_refused("TRUNCATE ledger_entries", /permission denied for table ledger_entries/)
    end
  end

  it "PR-13: refuses the app role every way around the triggers" do
    expect(triggers.map(&:first)).to include("trg_ledger_entries_immutable", "trg_audit_events_append_only",
                                             "trg_psp_calls_append_only", "trg_payment_transitions_append_only")
    as_role("payhub_app") do
      triggers.each do |trigger, table|
        expect_refused("ALTER TABLE #{table} DISABLE TRIGGER #{trigger}", /must be owner of table #{table}/)
        expect_refused("DROP TRIGGER #{trigger} ON #{table}", /must be owner of (table|relation) #{table}/)
      end
      expect_refused("ALTER TABLE ledger_entries DISABLE TRIGGER ALL", /must be owner of table ledger_entries/)
      expect_refused("SET session_replication_role = replica",
                     /permission denied to set parameter "session_replication_role"/)
      expect_refused(<<~SQL, /permission denied for schema public/) # before it gets as far as "must be owner"
        CREATE OR REPLACE FUNCTION public.append_only_guard() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN OLD; END $$
      SQL
      expect_refused("CREATE TRIGGER trg_roles_spec BEFORE INSERT ON payments FOR EACH ROW EXECUTE FUNCTION stamp_created_at()",
                     /permission denied for table payments/)
    end
  end

  it "PR-13: refuses the app role DDL, grants and roles" do
    acl = -> { conn.select_value("SELECT relacl::text FROM pg_class WHERE oid = 'payments'::regclass") }
    before_grant = acl.call
    as_role("payhub_app") do
      expect_refused("CREATE TABLE roles_spec (id int)", /permission denied for schema public/)
      expect_refused("CREATE TEMP TABLE merchant_users (id int)", /permission denied to create temporary tables in database/)
      expect_refused("ALTER TABLE payments ADD COLUMN roles_spec int", /must be owner of table payments/)
      expect_refused("DROP TABLE payments", /must be owner of table payments/)
      expect_refused("GRANT payhub_owner TO payhub_app", /permission denied to grant role "payhub_owner"/)
      expect_refused("ALTER ROLE payhub_app SUPERUSER", /permission denied to alter role/)
      # Without the grant option PostgreSQL only warns ("no privileges were
      # granted"); nothing may change.
      conn.execute("SET client_min_messages = error")
      conn.execute("GRANT SELECT ON payments TO PUBLIC")
      conn.execute("RESET client_min_messages")
    end
    expect(acl.call).to eq(before_grant)
  end

  it "PR-13: grants the app role what payhub_owner creates later (default privileges FOR ROLE payhub_owner)" do
    as_role("payhub_owner") { conn.execute("CREATE TABLE roles_spec (id bigserial PRIMARY KEY, note text)") }
    as_role("payhub_app") do
      conn.execute("INSERT INTO roles_spec (note) VALUES ('a')")
      conn.execute("UPDATE roles_spec SET note = 'b'")
      expect(conn.select_value("SELECT note FROM roles_spec")).to eq("b")
      conn.execute("DELETE FROM roles_spec")
      expect_refused("DROP TABLE roles_spec", /must be owner of table roles_spec/)
    end
  end

  # Independent of TEMPORARY being revoked: the example grants it back. The
  # trigger functions pin search_path (migration 20261021700001), so a temp
  # table cannot stand in for the one they read.
  describe "a temp table shadowing a table a trigger reads" do
    let(:merchant) { create(:merchant) }

    before do
      create(:merchant_user, merchant:, role: "owner")
      conn.execute("GRANT TEMPORARY ON DATABASE #{db} TO payhub_app")
    end

    it "PR-13: pins search_path on every function in public" do
      configs = conn.select_rows(<<~SQL)
        SELECT proname, array_to_string(proconfig, ';') FROM pg_proc p WHERE pronamespace = 'public'::regnamespace
          AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
      SQL
      expect(configs).not_to be_empty
      expect(configs).to all(match([anything, "search_path=public, pg_temp"]))
    end

    it "PR-13: does not let a fake owner row keep a merchant with no active owner" do
      as_role("payhub_app") do
        conn.execute("CREATE TEMP TABLE merchant_users (merchant_id uuid, disabled_at timestamp, role text)")
        conn.execute("INSERT INTO pg_temp.merchant_users VALUES (#{conn.quote(merchant.id)}, NULL, 'owner')")
        expect_refused(<<~SQL, /must keep one active owner/)
          UPDATE public.merchant_users SET role = 'admin' WHERE merchant_id = #{conn.quote(merchant.id)};
          SET CONSTRAINTS ALL IMMEDIATE
        SQL
      end
    end

    it "PR-13: does not let a fake live merchant make a twin of a test twin" do
      twin = create(:merchant)
      twin.update_columns(livemode: false, live_merchant_id: merchant.id) # rubocop:disable Rails/SkipsModelValidations
      other = create(:merchant)
      as_role("payhub_app") do
        conn.execute("CREATE TEMP TABLE merchants (id uuid, livemode boolean, live_merchant_id uuid)")
        conn.execute("INSERT INTO pg_temp.merchants VALUES (#{conn.quote(twin.id)}, true, NULL)")
        expect_refused("UPDATE public.merchants SET livemode = false, live_merchant_id = #{conn.quote(twin.id)} " \
                       "WHERE id = #{conn.quote(other.id)}", /a test twin has no twin/)
      end
    end
  end

  # created_at is `timestamp without time zone` in UTC. A session on another
  # TimeZone must not move stamp_created_at's stamp or the 12-month window.
  describe "a session on another time zone" do
    around do |example|
      conn.execute("SET timezone TO 'Pacific/Kiritimati'") # UTC+14
      example.run
    ensure
      conn.execute("SET timezone TO 'UTC'") # Rails' own session setting
    end

    it "PR-13: still stamps created_at in UTC" do
      event = AuditEvent.record!(action: "roles.spec", result: "success")
      expect(event.reload.created_at).to be_within(1.minute).of(Time.current)
    end

    it "PR-13: still refuses deleting an audit row a few hours inside the 12 months" do
      backdated_audit_event(12.months.ago + 10.hours)
      as_role("payhub_app") do
        expect_refused("DELETE FROM audit_events WHERE action = 'roles.spec'", /audit_events is append-only/)
      end
    end
  end
end
