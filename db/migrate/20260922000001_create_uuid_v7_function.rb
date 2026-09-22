class CreateUuidV7Function < ActiveRecord::Migration[7.2]
  # Postgres 16 has no native uuidv7(); PG 18 will. Until then, the standard
  # plpgsql implementation: 48-bit unix ms timestamp, version nibble 0111,
  # remaining 74 bits random. Time-ordered => good btree locality at 1M rows,
  # still unguessable => safe to expose in URLs.
  def up
    enable_extension "pgcrypto" unless extension_enabled?("pgcrypto")

    execute <<~SQL
      CREATE OR REPLACE FUNCTION uuid_generate_v7() RETURNS uuid AS $$
      DECLARE
        unix_ts_ms bytea;
        uuid_bytes bytea;
      BEGIN
        unix_ts_ms = substring(int8send(floor(extract(epoch from clock_timestamp()) * 1000)::bigint) from 3);
        uuid_bytes = uuid_send(gen_random_uuid());
        uuid_bytes = overlay(uuid_bytes placing unix_ts_ms from 1 for 6);
        uuid_bytes = set_byte(uuid_bytes, 6, (b'0111' || get_byte(uuid_bytes, 6)::bit(4))::bit(8)::int);
        RETURN encode(uuid_bytes, 'hex')::uuid;
      END
      $$ LANGUAGE plpgsql VOLATILE;
    SQL
  end

  def down
    execute "DROP FUNCTION IF EXISTS uuid_generate_v7()"
  end
end
