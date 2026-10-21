-- Least-privilege database roles (RUNBOOK "Database roles").
--
--   payhub_owner  owns every table, sequence and function in schema public;
--                 runs migrations (the RUN_MIGRATIONS=true release container).
--   payhub_app    web and worker. Reads and writes rows, nothing else: it owns
--                 nothing, so it cannot ALTER, DROP or DISABLE the append-only
--                 triggers, and it is no superuser, so it cannot set
--                 session_replication_role = replica to skip them.
--
-- Idempotent. Run it as a superuser in each database, connected to that
-- database (psql -d payhub_production -f db/roles.sql):
--   * once, before the first deploy with these roles (it also hands every
--     existing object in public to payhub_owner);
--   * again after any migration that ran as another role (tables payhub_owner
--     creates are granted to payhub_app automatically, by the default
--     privileges below).
-- Passwords are not set here: ALTER ROLE ... PASSWORD from the secrets manager.

-- Roles are cluster-wide. Two sessions running this at once can both pass
-- NOT EXISTS; the loser's CREATE then fails, which means the role exists.
DO $$
DECLARE
  r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['payhub_owner', 'payhub_app'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      BEGIN
        EXECUTE format('CREATE ROLE %I LOGIN', r);
      EXCEPTION WHEN duplicate_object OR unique_violation THEN
        NULL;
      END;
    END IF;
    -- Also corrects a role that was created by hand with more.
    EXECUTE format('ALTER ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS', r);
  END LOOP;
END $$;

-- CREATE on the database lets payhub_owner load db/structure.sql into an
-- empty one: CREATE EXTENSION pgcrypto (a trusted extension) needs it, and the
-- COMMENT ON EXTENSION after it needs payhub_owner to own the extension.
DO $$
BEGIN
  EXECUTE format('GRANT CONNECT, CREATE ON DATABASE %I TO payhub_owner', current_database());
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO payhub_app', current_database());
END $$;

-- Only payhub_owner creates objects. (PostgreSQL 15+ already has no CREATE for
-- PUBLIC on schema public; older versions did.)
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE, CREATE ON SCHEMA public TO payhub_owner;
GRANT USAGE ON SCHEMA public TO payhub_app;

-- payhub_owner owns everything in public: migrations ALTER and DROP what they
-- find. Sequences that belong to a column move with their table; extension
-- objects (pgcrypto) stay with the extension.
DO $$
DECLARE
  obj record;
BEGIN
  FOR obj IN
    SELECT c.oid::regclass::text AS name,
           CASE c.relkind WHEN 'S' THEN 'SEQUENCE' WHEN 'v' THEN 'VIEW'
                          WHEN 'm' THEN 'MATERIALIZED VIEW' ELSE 'TABLE' END AS kind
    FROM pg_class c
    WHERE c.relnamespace = 'public'::regnamespace
      AND c.relkind IN ('r', 'p', 'v', 'm', 'S')
      AND c.relowner <> 'payhub_owner'::regrole
      AND NOT EXISTS (SELECT 1 FROM pg_depend d
                      WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid
                        AND d.deptype IN ('a', 'i', 'e'))
  LOOP
    EXECUTE format('ALTER %s %s OWNER TO payhub_owner', obj.kind, obj.name);
  END LOOP;

  FOR obj IN
    SELECT p.oid::regprocedure::text AS name
    FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace
      AND p.proowner <> 'payhub_owner'::regrole
      AND NOT EXISTS (SELECT 1 FROM pg_depend d
                      WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
  LOOP
    EXECUTE format('ALTER ROUTINE %s OWNER TO payhub_owner', obj.name);
  END LOOP;
END $$;

-- Rows only: no TRUNCATE, REFERENCES or TRIGGER, no grant option.
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO payhub_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO payhub_app;

-- The same for every object payhub_owner creates later. FOR ROLE matters:
-- without it these apply only to objects created by the role running this
-- file (the superuser), not to the ones migrations create.
ALTER DEFAULT PRIVILEGES FOR ROLE payhub_owner IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO payhub_app;
ALTER DEFAULT PRIVILEGES FOR ROLE payhub_owner IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO payhub_app;
