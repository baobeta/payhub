import type { Permission } from "../shared/can";
import type { PaymentState } from "../shared/pollInterval";
import type { TimelineEntry } from "../shared/timeline";

export type { TimelineEntry } from "../shared/timeline";

export type Me = {
  user: { id: string; email: string; name: string | null; role: string };
  merchant: { id: string; name: string };
  livemode: boolean;
  stepped_up_until: string | null;
  permissions: Permission[];
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

export type PaymentDetail = Payment & {
  timeline: TimelineEntry[];
  can: { capture: boolean; cancel: boolean; refund: boolean; capturable_minor: number; refundable_minor: number };
};

export type List<T> = { data: T[]; has_more: boolean; next_cursor: string | null };
