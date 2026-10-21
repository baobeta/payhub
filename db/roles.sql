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
--   * again after the first db:prepare of an empty database, and after any
--     migration that ran as another role (tables payhub_owner creates are
--     granted to payhub_app automatically, by the default privileges below).
-- Run it with psql --single-transaction (-1) so a rerun on a live database
-- never shows the app a moment without its grants.
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
    -- Also strips the attributes of a role that was created by hand with more
    -- (its extra grants and memberships go below).
    EXECUTE format('ALTER ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS', r);
  END LOOP;
END $$;

-- The database. CREATE lets payhub_owner load db/structure.sql into an empty
-- one: CREATE EXTENSION pgcrypto (a trusted extension) needs it, and the
-- COMMENT ON EXTENSION after it needs payhub_owner to own the extension.
--
-- TEMPORARY is taken from PUBLIC: with a temp table a role can shadow a table
-- that a trigger function reads, since pg_temp comes first in the default
-- search_path (the functions also pin search_path, migration
-- 20261021700001). This affects every non-superuser role in this database,
-- not only payhub_app: grant TEMPORARY back by name to one that needs it.
-- Migrations do not, so payhub_owner does not get it.
DO $$
BEGIN
  EXECUTE format('REVOKE TEMPORARY ON DATABASE %I FROM PUBLIC', current_database());
  EXECUTE format('GRANT CONNECT, CREATE ON DATABASE %I TO payhub_owner', current_database());
END $$;

-- Only payhub_owner creates objects. (PostgreSQL 15+ already has no CREATE for
-- PUBLIC on schema public; older versions did.)
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE, CREATE ON SCHEMA public TO payhub_owner;

-- payhub_owner owns everything in public: migrations ALTER and DROP what they
-- find. Sequences that belong to a column move with their table, a table's
-- row type with the table; extension objects (pgcrypto) stay with the
-- extension.
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

  -- Enums, domains, standalone composite types and ranges (array types follow
  -- their element type).
  FOR obj IN
    SELECT t.oid::regtype::text AS name, CASE t.typtype WHEN 'd' THEN 'DOMAIN' ELSE 'TYPE' END AS kind
    FROM pg_type t
    LEFT JOIN pg_class c ON c.oid = t.typrelid
    WHERE t.typnamespace = 'public'::regnamespace
      AND t.typtype IN ('e', 'd', 'c', 'r')
      AND (t.typrelid = 0 OR c.relkind = 'c')
      AND t.typowner <> 'payhub_owner'::regrole
      AND NOT EXISTS (SELECT 1 FROM pg_depend d
                      WHERE d.classid = 'pg_type'::regclass AND d.objid = t.oid AND d.deptype = 'e')
  LOOP
    EXECUTE format('ALTER %s %s OWNER TO payhub_owner', obj.kind, obj.name);
  END LOOP;
END $$;

-- payhub_app: exactly these privileges, whatever it had before. Everything is
-- revoked first (extra grants such as TRUNCATE, role memberships), then
-- granted, in one statement so a concurrent query never sees the gap.
-- Rows only: no TRUNCATE, REFERENCES or TRIGGER, no grant option, no TEMP.
-- schema_migrations and ar_internal_metadata are read-only to it: Rails reads
-- them (pending-migration checks); only db: tasks write them, as payhub_owner.
DO $$
DECLARE
  m record;
BEGIN
  FOR m IN
    SELECT roleid::regrole::text AS role, grantor::regrole::text AS grantor
    FROM pg_auth_members WHERE member = 'payhub_app'::regrole
  LOOP
    EXECUTE format('REVOKE %I FROM payhub_app GRANTED BY %I CASCADE', m.role, m.grantor);
  END LOOP;

  EXECUTE format('REVOKE ALL ON DATABASE %I FROM payhub_app', current_database());
  REVOKE ALL ON SCHEMA public FROM payhub_app;
  REVOKE ALL ON ALL TABLES IN SCHEMA public FROM payhub_app;
  REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM payhub_app;
  REVOKE ALL ON ALL ROUTINES IN SCHEMA public FROM payhub_app;

  EXECUTE format('GRANT CONNECT ON DATABASE %I TO payhub_app', current_database());
  GRANT USAGE ON SCHEMA public TO payhub_app;
  GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO payhub_app;
  GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO payhub_app;
  IF to_regclass('public.schema_migrations') IS NOT NULL THEN
    REVOKE INSERT, UPDATE, DELETE ON public.schema_migrations FROM payhub_app;
  END IF;
  IF to_regclass('public.ar_internal_metadata') IS NOT NULL THEN
    REVOKE INSERT, UPDATE, DELETE ON public.ar_internal_metadata FROM payhub_app;
  END IF;
END $$;

-- The same for every table and sequence payhub_owner creates later. FOR ROLE
-- matters: without it these apply only to objects created by the role running
-- this file (the superuser), not to the ones migrations create.
-- (schema_migrations and ar_internal_metadata, created by the first
-- db:prepare of an empty database, get them too: rerun this file after it.)
--
-- None for functions: PUBLIC can EXECUTE every function, and a trigger
-- function runs with the privileges of the statement that fired it. A future
-- SECURITY DEFINER function runs as payhub_owner instead: give it
-- SET search_path = public, pg_temp and REVOKE EXECUTE ... FROM PUBLIC.
ALTER DEFAULT PRIVILEGES FOR ROLE payhub_owner IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO payhub_app;
ALTER DEFAULT PRIVILEGES FOR ROLE payhub_owner IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO payhub_app;
