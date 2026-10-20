class GuardPaymentTransitionsAppendOnly < ActiveRecord::Migration[8.1]
  # Payment history is written in pen (DOMAIN.md, DECISIONS #5, PCI 10.3.2):
  # the database refuses edits, deletes and TRUNCATE, not just ActiveRecord.
  # The one allowed change is Payment#transition! retiring the previous row:
  # most_recent true -> false with every other column untouched (compared as
  # the whole row minus most_recent, so a column added later is covered too).
  def up
    execute <<~SQL
      CREATE FUNCTION payment_transitions_append_only() RETURNS trigger
        LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_OP = 'UPDATE' AND OLD.most_recent AND NOT NEW.most_recent
           AND (to_jsonb(OLD) - 'most_recent') = (to_jsonb(NEW) - 'most_recent') THEN
          RETURN NEW;
        END IF;
        RAISE EXCEPTION 'payment_transitions is append-only (attempted %)', TG_OP;
      END
      $$;

      CREATE TRIGGER trg_payment_transitions_append_only BEFORE DELETE OR UPDATE ON payment_transitions
        FOR EACH ROW EXECUTE FUNCTION payment_transitions_append_only();
      CREATE TRIGGER trg_payment_transitions_no_truncate BEFORE TRUNCATE ON payment_transitions
        FOR EACH STATEMENT EXECUTE FUNCTION append_only_guard();
      CREATE TRIGGER trg_ledger_entries_no_truncate BEFORE TRUNCATE ON ledger_entries
        FOR EACH STATEMENT EXECUTE FUNCTION append_only_guard();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER trg_ledger_entries_no_truncate ON ledger_entries;
      DROP TRIGGER trg_payment_transitions_no_truncate ON payment_transitions;
      DROP TRIGGER trg_payment_transitions_append_only ON payment_transitions;
      DROP FUNCTION payment_transitions_append_only();
    SQL
  end
end
