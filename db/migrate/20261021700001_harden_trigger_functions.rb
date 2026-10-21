class HardenTriggerFunctions < ActiveRecord::Migration[8.1]
  # The trigger functions run as the role whose statement fired them, with
  # that session's search_path, which looks in pg_temp first. A role allowed
  # to create temp tables could shadow merchant_users or merchants with its
  # own and walk past merchant_users_keep_one_owner or
  # merchants_twin_parent_is_live (RUNBOOK "Database roles"). Pinning
  # search_path to public, then pg_temp (last: PostgreSQL's documented safe
  # form), makes every unqualified name mean the real table. Done for every
  # function in public, not only the two that read tables today, so a table
  # read added later is covered.
  #
  # The functions that read tables: merchant_users_keep_one_owner
  # (merchant_users), merchants_twin_parent_is_live (merchants). The rest
  # touch only NEW/OLD and built-ins.
  #
  # created_at is `timestamp without time zone` holding UTC (Rails). now()
  # converts to the session's TimeZone, so a session with SET timezone shifted
  # stamp_created_at's stamp and append_only_guard's 12-month window. Rails
  # sets every app connection to UTC, so for the app nothing changes;
  # `now() AT TIME ZONE 'UTC'` makes it hold for every other session too.
  FUNCTIONS = %w[
    append_only_guard() ledger_entries_immutable() merchant_users_keep_one_owner()
    merchants_twin_parent_is_live() operator_proposal_payload_immutable()
    payment_transitions_append_only() stamp_created_at() uuid_generate_v7()
  ].freeze

  def up
    safety_assured do # ALTER FUNCTION and CREATE OR REPLACE FUNCTION take no table locks
      execute <<~SQL
        CREATE OR REPLACE FUNCTION append_only_guard() RETURNS trigger
          LANGUAGE plpgsql AS $$
        BEGIN
          IF TG_OP = 'DELETE' AND TG_NARGS > 0
             AND OLD.created_at < (now() AT TIME ZONE 'UTC') - TG_ARGV[0]::interval THEN
            RETURN OLD;
          END IF;
          RAISE EXCEPTION '% is append-only (attempted %)', TG_TABLE_NAME, TG_OP;
        END
        $$;

        CREATE OR REPLACE FUNCTION stamp_created_at() RETURNS trigger
          LANGUAGE plpgsql AS $$
        BEGIN
          NEW.created_at := now() AT TIME ZONE 'UTC';
          RETURN NEW;
        END
        $$;
      SQL
      FUNCTIONS.each { |f| execute "ALTER FUNCTION public.#{f} SET search_path = public, pg_temp" }
    end
  end

  def down
    safety_assured do
      FUNCTIONS.each { |f| execute "ALTER FUNCTION public.#{f} RESET search_path" }
      execute <<~SQL
        CREATE OR REPLACE FUNCTION append_only_guard() RETURNS trigger
          LANGUAGE plpgsql AS $$
        BEGIN
          IF TG_OP = 'DELETE' AND TG_NARGS > 0
             AND OLD.created_at < now() - TG_ARGV[0]::interval THEN
            RETURN OLD;
          END IF;
          RAISE EXCEPTION '% is append-only (attempted %)', TG_TABLE_NAME, TG_OP;
        END
        $$;

        CREATE OR REPLACE FUNCTION stamp_created_at() RETURNS trigger
          LANGUAGE plpgsql AS $$
        BEGIN
          NEW.created_at := now();
          RETURN NEW;
        END
        $$;
      SQL
    end
  end
end
