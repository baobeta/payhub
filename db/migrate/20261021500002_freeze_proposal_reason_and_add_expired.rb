class FreezeProposalReasonAndAddExpired < ActiveRecord::Migration[8.1]
  # N6 (DECISIONS #23). Stripe Approvals approves a request exactly as it was
  # captured, and lets it expire after 14 days.
  # - The reason an approver read (reason_code, reason_text, case_reference)
  #   is frozen with the payload: to change it, withdraw and resubmit.
  # - `expired` joins the states. Like `withdrawn`, nobody decided it, so
  #   decided_at stays NULL.
  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION operator_proposal_payload_immutable() RETURNS trigger AS $$
      BEGIN
        IF NEW.payload IS DISTINCT FROM OLD.payload OR NEW.kind IS DISTINCT FROM OLD.kind
           OR NEW.payment_id IS DISTINCT FROM OLD.payment_id OR NEW.proposed_by_id IS DISTINCT FROM OLD.proposed_by_id
           OR NEW.reason_code IS DISTINCT FROM OLD.reason_code OR NEW.reason_text IS DISTINCT FROM OLD.reason_text
           OR NEW.case_reference IS DISTINCT FROM OLD.case_reference THEN
          RAISE EXCEPTION 'operator_proposals payload and reason are immutable; withdraw and resubmit';
        END IF;
        RETURN NEW;
      END
      $$ LANGUAGE plpgsql;
    SQL

    remove_check_constraint :operator_proposals, name: "chk_operator_proposals_state"
    add_check_constraint :operator_proposals, "state IN ('pending','withdrawn','rejected','applied','failed','expired')",
                         name: "chk_operator_proposals_state"
    remove_check_constraint :operator_proposals, name: "chk_operator_proposals_decided_shape"
    add_check_constraint :operator_proposals, "(state = 'pending') = (decided_at IS NULL) OR state IN ('withdrawn','expired')",
                         name: "chk_operator_proposals_decided_shape"
  end

  def down
    remove_check_constraint :operator_proposals, name: "chk_operator_proposals_decided_shape"
    add_check_constraint :operator_proposals, "(state = 'pending') = (decided_at IS NULL) OR state = 'withdrawn'",
                         name: "chk_operator_proposals_decided_shape"
    remove_check_constraint :operator_proposals, name: "chk_operator_proposals_state"
    add_check_constraint :operator_proposals, "state IN ('pending','withdrawn','rejected','applied','failed')",
                         name: "chk_operator_proposals_state"

    execute <<~SQL
      CREATE OR REPLACE FUNCTION operator_proposal_payload_immutable() RETURNS trigger AS $$
      BEGIN
        IF NEW.payload IS DISTINCT FROM OLD.payload OR NEW.kind IS DISTINCT FROM OLD.kind
           OR NEW.payment_id IS DISTINCT FROM OLD.payment_id OR NEW.proposed_by_id IS DISTINCT FROM OLD.proposed_by_id THEN
          RAISE EXCEPTION 'operator_proposals payload is immutable; withdraw and resubmit';
        END IF;
        RETURN NEW;
      END
      $$ LANGUAGE plpgsql;
    SQL
  end
end
