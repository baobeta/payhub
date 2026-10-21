class GuardTwinParentAndOneOwner < ActiveRecord::Migration[8.1]
  # L4 (DECISIONS #22): a test twin's parent is a live merchant. Sandboxes
  # don't nest (Stripe sandboxes), so a twin of a twin is refused here, not
  # only by Merchant#test_twin!. A merchant that has a twin can't turn into
  # one either.
  #
  # M10 (DECISIONS #22): a live merchant that has any active member keeps
  # exactly one active owner (Stripe: one owner, changed only by transfer).
  # The partial unique index already stops a second owner; this constraint
  # trigger stops zero. It is DEFERRABLE INITIALLY DEFERRED so it runs at
  # COMMIT: TransferOwnership demotes, then promotes, in one transaction, and
  # a brand-new merchant with no members yet passes.
  def up
    preflight!
    execute <<~SQL
      CREATE FUNCTION merchants_twin_parent_is_live() RETURNS trigger
        LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.live_merchant_id IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM merchants WHERE id = NEW.live_merchant_id AND livemode) THEN
          RAISE EXCEPTION 'merchants.live_merchant_id must point at a live merchant (a test twin has no twin)';
        END IF;
        IF NOT NEW.livemode AND EXISTS (SELECT 1 FROM merchants WHERE live_merchant_id = NEW.id) THEN
          RAISE EXCEPTION 'merchants.live_merchant_id must point at a live merchant (this merchant has a twin)';
        END IF;
        RETURN NEW;
      END
      $$;

      CREATE TRIGGER trg_merchants_twin_parent_is_live BEFORE INSERT OR UPDATE OF livemode, live_merchant_id ON merchants
        FOR EACH ROW EXECUTE FUNCTION merchants_twin_parent_is_live();

      CREATE FUNCTION merchant_users_keep_one_owner() RETURNS trigger
        LANGUAGE plpgsql AS $$
      DECLARE
        mid uuid;
      BEGIN
        -- Both sides of a row that moved merchants (raw SQL only; the app never does).
        FOREACH mid IN ARRAY ARRAY[NEW.merchant_id, OLD.merchant_id] LOOP
          IF mid IS NOT NULL
             AND EXISTS (SELECT 1 FROM merchant_users WHERE merchant_id = mid AND disabled_at IS NULL)
             AND NOT EXISTS (SELECT 1 FROM merchant_users WHERE merchant_id = mid AND disabled_at IS NULL AND role = 'owner') THEN
            RAISE EXCEPTION 'merchant % must keep one active owner while it has active members; transfer ownership instead', mid;
          END IF;
        END LOOP;
        RETURN NULL;
      END
      $$;

      CREATE CONSTRAINT TRIGGER trg_merchant_users_keep_one_owner
        AFTER INSERT OR UPDATE OR DELETE ON merchant_users
        DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION merchant_users_keep_one_owner();
    SQL
  end

  OWNERLESS_SQL = <<~SQL.squish
    SELECT m.id FROM merchants m
    WHERE m.livemode
      AND EXISTS (SELECT 1 FROM merchant_users u WHERE u.merchant_id = m.id AND u.disabled_at IS NULL)
      AND NOT EXISTS (SELECT 1 FROM merchant_users u
                      WHERE u.merchant_id = m.id AND u.disabled_at IS NULL AND u.role = 'owner')
    ORDER BY m.id
  SQL

  BAD_TWIN_SQL = <<~SQL.squish
    SELECT t.id FROM merchants t JOIN merchants p ON p.id = t.live_merchant_id
    WHERE NOT p.livemode ORDER BY t.id
  SQL

  # TC-M10-3: existing rows the triggers would refuse. The owner trigger only
  # checks rows that change, so bad data would otherwise slip in now and fail
  # some unrelated write later. Stop the deploy here instead, with the ids
  # (RUNBOOK "Deploy stopped: merchant without an owner").
  def preflight!
    problems = []
    ownerless = select_values(OWNERLESS_SQL)
    if ownerless.any?
      problems << "live merchants with active members but no active owner (promote one, see RUNBOOK): #{ownerless.join(', ')}"
    end
    bad_twins = select_values(BAD_TWIN_SQL)
    problems << "test twins whose parent is not live (re-point live_merchant_id): #{bad_twins.join(', ')}" if bad_twins.any?
    return if problems.empty?

    raise "GuardTwinParentAndOneOwner cannot install its triggers. Fix these first:\n- #{problems.join("\n- ")}"
  end

  def down
    execute <<~SQL
      DROP TRIGGER trg_merchant_users_keep_one_owner ON merchant_users;
      DROP FUNCTION merchant_users_keep_one_owner();
      DROP TRIGGER trg_merchants_twin_parent_is_live ON merchants;
      DROP FUNCTION merchants_twin_parent_is_live();
    SQL
  end
end
