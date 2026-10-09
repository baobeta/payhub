import type { Permission } from "../shared/can";
import type { PaymentState } from "../shared/pollInterval";
import type { TimelineEntry } from "../shared/timeline";

export type OpsMe = {
  user: { id: string; email: string; name: string | null; role: string };
  stepped_up_until: string | null;
  permissions: Permission[];
  impersonating: {
    merchant_id: string;
    merchant_name: string | null;
    case_ref: string | null;
    expires_at: string | null;
  } | null;
};

export type Payment = {
  id: string;
  state: PaymentState;
  amount_minor: number;
  currency: string;
  captured_minor: number;
  psp_name: string;
  psp_reference: string;
  created_at: string;
  updated_at: string;
};

export type QueuePayment = {
  id: string;
  merchant: string;
  psp_name: string;
  psp_reference: string;
  amount_minor: number;
  currency: string;
  stuck_since: string;
  check_attempts: number;
};

export type QueueEvent = {
  id: string;
  merchant: string;
  type: string;
  payment_id: string | null;
  last_error: string | null;
  dead_since: string;
};

export type Queue = {
  unknown_payments: QueuePayment[];
  dead_events: QueueEvent[];
  reconciliation_breaks: number;
  open_proposals: number;
};

export type SearchRow = Payment & { merchant: string; merchant_id: string; livemode: boolean };

export type PspCall = {
  operation: string;
  http_status: number | null;
  outcome: string;
  duration_ms: number | null;
  request_redacted: unknown;
  response_redacted: unknown;
  sent_at: string;
};

export type InboundEvent = {
  event_type: string;
  signature_valid: boolean;
  error: string | null;
  payload: unknown;
  received_at: string;
  processed_at: string | null;
};

export type Proposal = {
  id: string;
  kind: string;
  payment_id: string;
  merchant: string;
  payload: Record<string, unknown>;
  reason_code: string;
  reason_text: string;
  case_reference: string;
  state: string;
  proposed_by: string;
  decided_by: string | null;
  decision_note: string | null;
  created_at: string;
  decided_at: string | null;
  applied_at: string | null;
  applied_transfer_id: string | null;
  error: string | null;
  can: { approve: boolean; reject: boolean; withdraw: boolean };
};

export type PaymentDetail = Payment & {
  merchant: { id: string; name: string; livemode: boolean };
  timeline: TimelineEntry[];
  psp_calls: PspCall[];
  inbound_events: InboundEvent[];
  proposals: Proposal[];
};

export type Circuit = {
  psp: string;
  state: string;
  open_until: string | null;
  window_calls: number;
  window_failures: number;
};

export type SettlementBreak = {
  id: string;
  psp_name: string;
  external_id: string;
  kind: string;
  status: string;
  problem: string | null;
  payment_id: string | null;
  psp_reference: string | null;
  gross_minor: number;
  fee_minor: number;
  net_minor: number;
  currency: string;
  settled_on: string;
  reviewed_at: string | null;
  reviewed_by_id: string | null;
  review_note: string | null;
};

export type Reconciliation = {
  settlement_lines: SettlementBreak[];
  ledger: { unbalanced_transfer_ids: string[]; reservation_drift_refund_ids: string[] };
};

export type OperatorRow = {
  id: string;
  email: string;
  role: string;
  disabled_at: string | null;
  last_sign_in_at: string | null;
};

export type AuditRow = {
  id: string;
  at: string;
  actor_type: string;
  actor: string;
  action: string;
  result: string;
  merchant_id: string | null;
  on_behalf_of_merchant_id: string | null;
  target_type: string | null;
  target_id: string | null;
  ip: string | null;
  metadata: Record<string, unknown>;
};

export type List<T> = { data: T[]; has_more?: boolean; next_cursor?: string | null };
